import AppKit
import Foundation

/// Watches the pointer and decides when a preview bubble should open, change or close,
/// and dispatches the modifier-click shortcuts bound to Dock icons.
///
/// Hover detection uses a global `NSEvent` monitor rather than a `CGEventTap`. Measured,
/// the monitor drops events — 73 of 100 delivered, 16.7 ms median gap — which is fine for
/// "is the pointer resting on an icon" and avoids taking on a second tap.
///
/// Reading the Dock is comparatively expensive, so a cheap geometric gate runs first:
/// only when the pointer is within a strip along the Dock's screen edge does the
/// Accessibility query run at all.
@MainActor
final class DockWatcher: BubbleKeyboardHandling {
    private let panelController: PreviewPanelController
    private let windowManager: WindowManager
    private var monitor: Any?
    private let observers = NotificationObserverBag()

    private var activationTask: Task<Void, Never>?
    private var pointerQueryTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Invalidates thumbnail callbacks and other work belonging to an older bubble.
    private var bubbleGeneration: UInt = 0

    /// The tile the bubble is currently open for.
    private var activeTile: AXCore.DockTile?
    private var activeApplication: NSRunningApplication?
    /// The windows the open bubble is showing, so a batch action knows its targets
    /// without asking for the list again and risking a different answer.
    private var activeWindows: [WindowInfo] = []

    /// The most recent Dock tile geometry, kept so the event tap can hit-test a click
    /// without making an Accessibility call on the event delivery path.
    private var tileSnapshot: [AXCore.DockTile] = []

    private var dockStrip: CGRect = .zero
    /// The display `dockStrip` was computed for, so a pointer arriving on a different
    /// screen can force a refresh instead of hit-testing against another monitor's Dock.
    private var dockScreen: NSScreen?
    private var dockEdge: DockEdge = .bottom
    private var lastStripRefresh: Date = .distantPast

    private var lastTileQuery: Date = .distantPast
    private var lastBubbleScroll: Date = .distantPast
    private var isQuerying = false

    /// Re-checks the Dock while the pointer sits in the strip but no tile is under it.
    ///
    /// With auto-hide, the icons slide up over a couple of hundred milliseconds. A
    /// pointer that arrives and then holds perfectly still generates no further mouse
    /// events, so without this the reveal would finish with nothing left to notice it and
    /// the bubble would never open.
    private var revealTask: Task<Void, Never>?

    /// Closes a bubble the pointer has silently left. See `startPresenceWatchdog`.
    private var presenceTask: Task<Void, Never>?

    /// Re-aims a newly opened bubble once the Dock has settled. See `startAnchorSettle`.
    private var anchorSettleTask: Task<Void, Never>?

    /// Where the pointer was on the previous event, for hover-intent.
    private var previousPointer: CGPoint?

    /// The screen the pointer was on at the previous event, so crossing displays is seen
    /// as the single moment it is rather than as a state that lasts.
    private var previousPointerScreen: NSScreen?

    /// The Dock's thickness — the short side of its tiles' union — from the last
    /// geometry refresh. Used to tell whether the pointer on another display is close
    /// enough to that display's Dock edge to pull the Dock across.
    private var dockThickness: CGFloat = 0

    /// An application this process has just asked to come forward from a bubble that
    /// stays open, and until when its activation is expected.
    ///
    /// With "hide when a preview is clicked" turned off, raising the clicked window
    /// activates its application, and the activation observer — which closes the bubble
    /// for any application coming forward — took the bubble down anyway. The setting
    /// therefore only ever worked for windows of the application that was already in front.
    private var expectedActivation: (pid: pid_t, deadline: Date)?

    init(panelController: PreviewPanelController, windowManager: WindowManager) {
        self.panelController = panelController
        self.windowManager = windowManager
    }

    // MARK: - Lifecycle

    func start() {
        guard monitor == nil else { return }
        guard let installedMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved],
            handler: { [weak self] _ in
                Task { @MainActor in self?.pointerMoved() }
            }
        ) else {
            Log.dock.error("could not create global mouse monitor")
            return
        }
        monitor = installedMonitor

        // Plugging in a display, changing resolution or rearranging monitors moves both
        // the Dock and the coordinate origin, invalidating the cached strip.
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeBubble()
                await self?.refreshDockGeometry()
            }
        }
        observers.insert(screenObserver, center: .default)

        // A Space switch takes the pointer somewhere the bubble no longer describes, and
        // it arrives without any mouse-moved event to notice it by.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let spaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closeBubble() }
        }
        observers.insert(spaceObserver, center: workspaceCenter)

        // Another application coming forward means the user has moved on, and one case
        // matters more than the rest: Mission Control runs as the Dock, and the bubble
        // sits at `.popUpMenu` level across all Spaces — so an open bubble is drawn *over*
        // Mission Control and swallows the clicks meant for the windows behind it. Waiting
        // for the pointer watchdog is too slow when the thing being covered is the picker
        // the user is trying to use.
        let activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            // Read here: `Notification` is not Sendable, a pid is.
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in self?.applicationActivated(pid: pid) }
        }
        observers.insert(activationObserver, center: workspaceCenter)

        // AX application elements are process-specific. Retaining one after its process
        // exits is both useless and an unbounded cache growth path over a long session.
        let terminationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            AXCore.shared.forget(pid: application.processIdentifier)
        }
        observers.insert(terminationObserver, center: workspaceCenter)

        windowManager.keyboardTarget = self
        windowManager.dockClickHandler = { [weak self] location, modifiers, button in
            self?.handleDockClick(at: location, modifiers: modifiers, button: button) ?? false
        }

        windowManager.bubbleScrollHandler = { [weak self] location, deltaY, deltaX, momentum in
            self?.handleBubbleScroll(at: location, deltaY: deltaY, deltaX: deltaX,
                                     isMomentum: momentum) ?? false
        }

        Task { await refreshDockGeometry() }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pointerQueryTask?.cancel()
        pointerQueryTask = nil
        isQuerying = false
        observers.removeAll()
        windowManager.keyboardTarget = nil
        windowManager.dockClickHandler = nil
        windowManager.bubbleScrollHandler = nil
        closeBubble()
    }

    // MARK: - Pointer handling

    private func pointerMoved() {
        let preferences = Preferences.shared
        guard preferences.windowPreviewsEnabled, !preferences.disabled else {
            closeBubble()
            return
        }
        guard Permissions.shared.hasAccessibility else { return }

        // The Dock's accessibility tree keeps reporting tiles at their usual positions
        // while Mission Control is presented, so without this the pointer dipping to the
        // bottom of the screen opens a preview bubble on top of Mission Control.
        if MissionControlDetector.isActive {
            closeBubble()
            return
        }

        let mouse = NSEvent.mouseLocation
        defer { previousPointer = mouse }

        // Moving into the bubble itself must not dismiss it — that is how the user
        // reaches the previews.
        if panelController.contains(screenPoint: mouse) {
            cancelDismissal()
            return
        }

        // The cached strip belongs to one display. On a multi-display Mac the Dock
        // follows the pointer to whichever screen it was last pushed against, so a strip
        // computed for the previous screen is not merely stale, it is on the wrong
        // monitor — and the five-second timer would leave hovering dead there for up to
        // that long. Crossing to another screen refreshes immediately.
        //
        // Only the crossing itself, and the approach to that screen's Dock edge, count.
        // This used to test "the pointer is on a screen other than the Dock's", which
        // stays true the whole time the user works on the other display: every mouse
        // event there re-read the entire Dock over Accessibility, at the 0.3 s throttle,
        // indefinitely. The Dock can only move to this screen when the pointer is pushed
        // against its Dock edge, so that is the one place worth watching continuously.
        let pointerScreen = ScreenGeometry.screen(containing: mouse)
        let crossedScreens = previousPointerScreen != nil && pointerScreen !== previousPointerScreen
        previousPointerScreen = pointerScreen
        let reachingForDock = dockScreen != nil && pointerScreen !== dockScreen
            && pointerScreen.map {
                Self.isNearDockEdge(mouse, of: $0.frame, edge: dockEdge,
                                    thickness: dockThickness)
            } == true
        if crossedScreens || reachingForDock || Date().timeIntervalSince(lastStripRefresh) > 5 {
            // Still throttled, or a pointer sweeping along a screen boundary would queue
            // an Accessibility query on every event.
            if Date().timeIntervalSince(lastStripRefresh) > 0.3 {
                Task { await refreshDockGeometry() }
            }
        }

        guard dockStrip.contains(mouse) else {
            // Hover intent: leaving the Dock strip *towards* an open bubble is the user
            // reaching for it, not leaving. Dismissing there is the classic hover-menu
            // failure — the target vanishes exactly as you move to it.
            if isMovingTowardBubble(from: previousPointer, to: mouse) {
                cancelDismissal()
                return
            }
            scheduleDismissal()
            return
        }

        // Inside the strip: ask the Dock where its icons actually are. Throttled, and
        // never re-entrant, because with auto-hide the frames change continuously during
        // the reveal animation and each query costs real time.
        guard !isQuerying, Date().timeIntervalSince(lastTileQuery) > 0.05 else { return }
        lastTileQuery = Date()
        isQuerying = true

        pointerQueryTask = Task { [weak self] in
            let tiles = await AXCore.shared.dockTiles()
            guard let self else { return }
            self.pointerQueryTask = nil
            self.isQuerying = false
            guard !Task.isCancelled, self.monitor != nil else { return }
            self.tileSnapshot = tiles
            // Judged against where the pointer is *now*, not where it was when the query
            // began. The query takes real time, and events that arrived meanwhile have
            // already been handled with newer positions: a pointer that has since left
            // the strip was already given its dismissal, and evaluating the old position
            // afterwards re-armed an activation for an icon the user had left. A pointer
            // that has reached the bubble, or left the strip, is the newer events' to
            // decide; this answer is only still relevant inside the strip.
            let current = NSEvent.mouseLocation
            guard !self.panelController.contains(screenPoint: current),
                  self.dockStrip.contains(current) else { return }
            self.evaluate(tiles: tiles, mouse: current)
        }
    }

    /// True when the pointer is heading into the open bubble.
    ///
    /// Deliberately simple: a strict "safe triangle" between the cursor and the bubble's
    /// far corners is the textbook solution, but it misfires when the bubble is wide and
    /// the pointer is near its edge. Requiring movement toward the bubble plus proximity
    /// covers the real case — a diagonal reach — without stranding the bubble open when
    /// the user is plainly going somewhere else.
    private func isMovingTowardBubble(from previous: CGPoint?, to current: CGPoint) -> Bool {
        guard panelController.isVisible, let previous else { return false }
        let bubble = panelController.frame
        guard !bubble.isEmpty else { return false }

        // Only within a short reach of the bubble; beyond that the user has moved on.
        let reach: CGFloat = 90
        guard bubble.insetBy(dx: -reach, dy: -reach).contains(current) else { return false }

        let toBubble = CGPoint(x: bubble.midX - previous.x, y: bubble.midY - previous.y)
        let travel = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
        // A positive dot product means the movement has a component toward the bubble.
        return toBubble.x * travel.x + toBubble.y * travel.y > 0
    }

    private func evaluate(tiles: [AXCore.DockTile], mouse: CGPoint) {
        guard let hit = tile(at: mouse, in: tiles) else {
            // Off every icon: abandon any countdown so returning to the same icon starts
            // a fresh one rather than being suppressed as "already pending".
            activationTask?.cancel()
            pendingTile = nil
            scheduleRevealRecheck()
            scheduleDismissal()
            return
        }
        revealTask?.cancel()
        revealTask = nil

        if hit.bundleURL == activeTile?.bundleURL {
            cancelDismissal()
            // Back on the icon whose bubble is showing: a countdown started for another
            // icon on the way here is no longer wanted. Left running, a quick A → B → A
            // opened B's bubble while the pointer rested on A.
            activationTask?.cancel()
            activationTask = nil
            pendingTile = nil
            // The icon may have moved since its bubble opened — the Dock was still
            // sliding in, or magnification has grown it — so keep the bubble aimed at it.
            activeTile = hit
            panelController.reanchor(to: hit.frame)
            return
        }
        scheduleActivation(for: hit)
    }

    /// Polls briefly while a hidden Dock finishes revealing under a still pointer.
    ///
    /// A `Task` loop rather than a `Timer`: the timer's closure is not isolated to the
    /// main actor, so its captured state trips Swift 6's concurrency checking, whereas
    /// this stays on the actor throughout.
    private func scheduleRevealRecheck() {
        guard revealTask == nil else { return }
        revealTask = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { return }
                let mouse = NSEvent.mouseLocation
                guard self.dockStrip.contains(mouse) else {
                    self.revealTask = nil
                    return
                }
                let tiles = await AXCore.shared.dockTiles()
                guard !Task.isCancelled else { return }
                self.tileSnapshot = tiles
                if self.tile(at: NSEvent.mouseLocation, in: tiles) != nil {
                    self.revealTask = nil
                    self.evaluate(tiles: tiles, mouse: NSEvent.mouseLocation)
                    return
                }
            }
            self?.revealTask = nil
        }
    }

    private func tile(at appKitPoint: CGPoint, in tiles: [AXCore.DockTile]) -> AXCore.DockTile? {
        tiles.first { tile in
            guard tile.isApplication, tile.isRunning else { return false }
            return ScreenGeometry.appKitRect(fromAccessibility: tile.frame).contains(appKitPoint)
        }
    }

    // MARK: - Dock click shortcuts

    /// Called from the event tap. Must not block and must not touch Accessibility, so it
    /// hit-tests against the tile geometry captured on the last hover.
    ///
    /// - Parameter location: pointer position in Accessibility (top-left origin) space.
    /// - Returns: true when the click was consumed by a binding.
    private func handleDockClick(at location: CGPoint,
                                 modifiers: ModifierCombo,
                                 button: DockMouseButton) -> Bool {
        guard !Preferences.shared.disabled else { return false }

        let appKitPoint = ScreenGeometry.appKitPoint(fromAccessibility: location)
        guard dockStrip.contains(appKitPoint),
              let tile = tile(at: appKitPoint, in: tileSnapshot),
              let bundleURL = tile.bundleURL,
              let application = runningApplication(for: bundleURL)
        else { return false }

        // An unmodified left click is the Dock's own job — never take it.
        if modifiers.isEmpty && button == .left {
            if Preferences.shared.hideWhenDockItemClicked { closeBubble() }
            return false
        }

        guard let action = DockShortcutStore.shared.action(
            forBundle: application.bundleIdentifier,
            modifiers: modifiers,
            button: button
        ) else {
            if Preferences.shared.hideWhenDockItemClicked { closeBubble() }
            return false
        }

        closeBubble()
        WindowActions.perform(action, on: application)
        return true
    }

    // MARK: - Bubble lifecycle

    /// The tile an activation is already counting down for.
    private var pendingTile: URL?

    /// A pending hover supersedes the currently displayed tile. With no pending hover,
    /// refreshes for the displayed bubble remain valid even after the pointer left it.
    private func isCurrentRequest(for bundleURL: URL) -> Bool {
        if let pendingTile { return pendingTile == bundleURL }
        return activeTile?.bundleURL == bundleURL
    }

    private func scheduleActivation(for tile: AXCore.DockTile) {
        cancelDismissal()

        // Restarting the countdown on every pointer event would mean it never finishes:
        // the pointer is re-sampled roughly every 50 ms while it rests on an icon, and
        // the activation delay defaults to 70 ms, so the tiniest hand movement kept
        // resetting the timer and the bubble never appeared. Only a move to a *different*
        // icon should restart it.
        guard pendingTile != tile.bundleURL else { return }

        activationTask?.cancel()
        pendingTile = tile.bundleURL

        let delay = Self.activationDelay(milliseconds: Preferences.shared.activationDelay)
        activationTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.openBubble(for: tile)
        }
    }

    /// The hover countdown for a stored activation delay, bounded to what the settings
    /// field offers.
    ///
    /// The stored value is whatever was typed: the field's stepper is bounded but its text
    /// is not, and `defaults write` bypasses both. Converted unbounded, a large value
    /// overflowed the nanosecond multiplication — a trap, on the first hover, every launch.
    nonisolated static func activationDelay(milliseconds: Int) -> Duration {
        .milliseconds(min(max(0, milliseconds), 5000))
    }

    private func openBubble(
        for tile: AXCore.DockTile,
        queryPurpose: WindowIndex.QueryPurpose = .interactivePreview
    ) async {
        guard let bundleURL = tile.bundleURL else {
            Log.dock.error("openBubble: \(tile.title, privacy: .public) has no bundle URL")
            pendingTile = nil
            return
        }
        guard let application = runningApplication(for: bundleURL) else {
            Log.dock.error("openBubble: no running app for \(bundleURL.path, privacy: .public)")
            pendingTile = nil
            return
        }

        let pid = application.processIdentifier
        let options = WindowQueryOptions.current()
        let windows = await WindowIndex.shared.windows(
            forPID: pid,
            preferences: options,
            purpose: queryPurpose
        )
        guard !Task.isCancelled, isCurrentRequest(for: bundleURL) else { return }
        await ThumbnailEngine.shared.prune(keeping: Set(windows.map(\.id)))
        guard !Task.isCancelled, isCurrentRequest(for: bundleURL) else { return }
        Log.dock.debug("open \(tile.title, privacy: .public): \(windows.count) windows")

        guard !windows.isEmpty else { closeBubble(); return }
        if windows.count == 1 && Preferences.shared.skipWhenSingleWindow {
            closeBubble()
            return
        }

        activeTile = tile
        activeApplication = application
        bubbleGeneration &+= 1

        panelController.show(
            windows: windows,
            applicationName: tile.title,
            tileFrame: tile.frame,
            edge: dockEdge,
            onSelect: { [weak self] window in self?.select(window) },
            onClose: { [weak self] window in self?.close(window) },
            onNewWindow: { [weak self] in
                guard let application = self?.activeApplication else { return }
                WindowActions.newWindow(for: application)
                self?.closeBubble()
            },
            onMinimizeAll: { [weak self] in
                guard let application = self?.activeApplication else { return }
                WindowActions.minimizeAllWindows(application)
                self?.closeBubble()
            },
            onCloseAll: { [weak self] in self?.closeAll() },
            onTileAll: { [weak self] in
                guard let application = self?.activeApplication else { return }
                WindowActions.tileWindows(of: application)
                self?.closeBubble()
            }
        )

        activeWindows = windows
        startThumbnailCapture(for: windows)
        startPeriodicRefresh(for: windows)
        startPresenceWatchdog()
        startAnchorSettle(for: bundleURL)
    }

    /// Re-reads the icon's frame once the Dock has had time to finish moving.
    ///
    /// `evaluate` re-anchors on pointer movement, but the common case needs no movement at
    /// all: the pointer pushes into an auto-hidden Dock and rests, the bubble opens from a
    /// frame taken mid-slide, and the Dock finishes sliding under a still pointer that
    /// produces no further events. One look after the reveal animation is enough.
    private func startAnchorSettle(for bundleURL: URL) {
        anchorSettleTask?.cancel()
        anchorSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let tiles = await AXCore.shared.dockTiles()
            guard !Task.isCancelled, let self,
                  self.activeTile?.bundleURL == bundleURL,
                  let tile = tiles.first(where: { $0.bundleURL == bundleURL })
            else { return }
            self.tileSnapshot = tiles
            self.activeTile = tile
            self.panelController.reanchor(to: tile.frame)
        }
    }

    /// Handles a scroll landing on the preview bubble.
    ///
    /// An upward flick over a preview selects that window, which is the same thing a click
    /// on it does. On a trackpad the two are one continuous motion — the fingers are
    /// already resting on the card — so this saves the deliberate press that interrupts it.
    ///
    /// Everything else over the bubble is swallowed rather than passed on: the bubble
    /// floats above other windows, and a scroll aimed at it must not reach whichever one
    /// is behind it.
    private func handleBubbleScroll(at location: CGPoint, deltaY: Int64, deltaX: Int64,
                                    isMomentum: Bool) -> Bool {
        guard panelController.isVisible else { return false }
        let point = ScreenGeometry.appKitPoint(fromAccessibility: location)
        guard panelController.contains(screenPoint: point) else { return false }

        // Coasting is an echo of a flick already acted on, and it outlives the throttle:
        // momentum events keep arriving for up to a second while the pointer may have
        // moved to a different card. Swallowed, never acted on.
        guard !isMomentum else { return true }

        // Only a *dominantly* vertical movement is a gesture aimed at a card. A sideways
        // swipe carries a stray ±1 on the vertical axis, and acting on that sign turns a
        // horizontal sweep into an accidental minimise.
        guard abs(deltaY) > abs(deltaX) else { return true }

        // "Upward" is a physical gesture, not a sign. With natural scrolling — the
        // system default — fingers moving up report a *negative* vertical delta; with it
        // off, a positive one. Reading the raw sign selected on the opposite gesture for
        // every natural-scrolling user (measured here: swipescrolldirection = 1, upward
        // flicks arrived negative and were swallowed without selecting).
        let naturalScrolling = (UserDefaults.standard
            .object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
        let upward = naturalScrolling ? deltaY < 0 : deltaY > 0

        // A flick sends a burst of events. Only the first is acted on, or one gesture
        // would fire a dozen times over — and the shared stamp also keeps the tail of an
        // upward flick from being read as a downward one.
        guard deltaY != 0, Date().timeIntervalSince(lastBubbleScroll) > 0.5 else { return true }
        lastBubbleScroll = Date()

        // Whichever card the pointer is over — the model already tracks it for the hover
        // highlight, so no geometry has to be recomputed here.
        guard let window = panelController.focusedWindow else { return true }

        // The two vertical gestures mirror each other: up brings the window to the user,
        // down puts it away.
        if upward {
            select(window)
        } else {
            minimize(window)
        }
        return true
    }

    /// Minimises a window from its preview card, leaving the bubble up.
    ///
    /// The bubble stays because putting a window away is housekeeping, not navigation:
    /// the user is often sweeping the row and parking several windows in one visit, and
    /// closing the bubble would make each one cost a fresh hover. The reload keeps the
    /// card honest — it stays in the row wearing its minimised look.
    private func minimize(_ window: WindowInfo) {
        Task { [weak self] in
            _ = await AXCore.shared.setMinimized(true, window: window.id,
                                                 pid: window.pid)
            await self?.reloadActiveBubble()
        }
    }

    /// Switches to a window, crossing to its Space first when it lives on another one.
    ///
    /// Without the Space switch this silently does nothing for any off-Space window,
    /// because Accessibility cannot even see such a window to raise it — which is most
    /// of what this feature exists to show.

    private func select(_ window: WindowInfo) {
        // Where to go, resolved against the window server *now*.
        //
        // Never from the snapshot taken when the bubble opened: that goes stale as soon as
        // the current Space changes — which the previous click may itself have caused —
        // and acting on it switches *away* from the Space the window is on.
        //
        // The card can also outlive the window it names. Some applications retire and
        // recreate their windows constantly, so by the time a card is clicked its window
        // may be on no Space at all; without the fallback the click silently degrades into
        // "activate the application", which brings it up on the desktop already showing.
        let activationTarget = CGS.activationTargetToReach(window: window.id, pid: window.pid)
        let destination = activationTarget?.space

        // "Hide when a preview is clicked" turned off means the user wants to keep
        // scanning the same application's windows — so leave the bubble up. Reaching
        // another Space is the exception: the panel joins all Spaces, so it would be
        // captured into the transition and slide across with the desktop.
        guard Preferences.shared.hideWhenPreviewClicked || destination != nil else {
            // Only what could open a *different* bubble is stopped. `cancelWork` also
            // stops thumbnail capture and refresh and invalidates their generation, which
            // left the bubble that is staying up with frozen or missing previews.
            activationTask?.cancel()
            activationTask = nil
            pendingTile = nil
            cancelDismissal()
            // The raise activates the window's application, and that activation must not
            // be read as the user moving on.
            expectedActivation = (window.pid, Date().addingTimeInterval(1.5))
            Task { @MainActor [weak self] in
                await self?.raise(window)
            }
            return
        }

        cancelWork()

        // Tear the bubble down *before* touching Spaces, and wait for it to finish.
        //
        // The panel carries `.canJoinAllSpaces`, so it exists on both the Space being
        // left and the one being entered. Starting a switch while it is still on screen
        // lets the WindowServer capture it into the transition snapshot, and it visibly
        // slides across with the desktop — the flash. Once the panel is genuinely off
        // screen there is nothing left to capture.
        panelController.hide { [weak self] in
            Task { @MainActor in
                if let activationTarget,
                   await self?.switchDesktops(to: activationTarget.space,
                                              windowID: activationTarget.windowID,
                                              pid: window.pid) != true {
                    // Activation may have made the application create an unplaced
                    // replacement even though the Dock declined to follow. Never force
                    // a quiet Space switch; clean up that exact failure shape instead.
                    await self?.correctUnplacedSurface(pid: window.pid,
                                                       expectedFrame: window.frame)
                    self?.activeTile = nil
                    self?.activeApplication = nil
                    self?.activeWindows = []
                    return
                }
                await self?.raise(window)
                self?.activeTile = nil
                self?.activeApplication = nil
                self?.activeWindows = []
                await self?.correctUnplacedSurface(pid: window.pid,
                                                   expectedFrame: window.frame)
            }
        }
    }

    /// Checks that selecting a preview did not leave the application showing a window
    /// that belongs to no Space, and goes to where its real window lives if it did.
    ///
    /// A window the window server places on no Space is not composited into any desktop.
    /// It is drawn over whichever desktop happens to be showing, Mission Control builds no
    /// tile for it — so it cannot be selected there — and it disappears the moment the
    /// user swipes to another desktop. That is exactly the shape of the reported failure:
    /// an application whose window lives on desktop 4 appearing on desktop 3, unselectable
    /// in Mission Control, and gone again after a swipe.
    ///
    /// Measured on Surge Dashboard, which retires its window and recreates it under a new
    /// id, leaving the replacement unplaced. Nothing in the selection path can prevent an
    /// application from doing that, so this checks the result instead of the intent.
    ///
    /// Runs once. Correcting a correction would be a loop, and the second reading is no
    /// more trustworthy than the first.
    private func correctUnplacedSurface(pid: pid_t, expectedFrame: CGRect) async {
        // Let the application settle: it may still be putting its window up.
        try? await Task.sleep(for: .milliseconds(350))

        var unplacedSurface: CGS.RawWindow?

        for entry in CGS.applicationWindows(pid: pid) {
            guard entry.layer == 0, entry.isOnScreen else { continue }
            let spaces = CGS.spaces(forWindow: entry.id)
            // Menu-bar strips and other slivers are always unplaced and always on screen;
            // they are not what the user clicked a preview to see. A separate legitimate
            // window on this Space must not suppress a matching ghost.
            guard spaces.isEmpty,
                  entry.frame.width >= 200,
                  entry.frame.height >= 200,
                  CGS.framesDescribeSameSurface(entry.frame, expectedFrame)
            else { continue }
            if let existing = unplacedSurface,
               existing.frame.width * existing.frame.height
                    >= entry.frame.width * entry.frame.height { continue }
            unplacedSurface = entry
        }

        guard let ghost = unplacedSurface else { return }
        guard let target = CGS.activationTargetToReach(window: ghost.id, pid: pid) else {
            return
        }

        guard await switchDesktops(to: target.space, windowID: target.windowID, pid: pid)
        else { return }
        _ = await AXCore.shared.raise(window: target.windowID, pid: pid,
                                      fallbackActivate: false)
    }

    /// Crosses to another desktop the way the system itself would.
    ///
    /// Not via `CGSManagedDisplaySetCurrentSpace` when it can be helped. That call moves
    /// the window server's compositing and bookkeeping but never tells the Dock, which
    /// owns Spaces: after a quiet switch the Dock still believes the user is on the old
    /// desktop, so Mission Control presents the old desktop's windows — with the newly
    /// shown window visibly floating on screen yet absent from Mission Control's model
    /// and impossible to select there. Measured directly: after quiet switches, Mission
    /// Control's tile list stayed the old desktop's regardless of what was on screen.
    ///
    /// The route the Dock respects is its own activation follow-through: activating an
    /// application whose main window lives on another Space makes the Dock itself perform
    /// the full transition. So: make the clicked window the application's main window,
    /// yield activation to it — the panel click made this process active, and since
    /// macOS 14 activation is cooperative, the explicit yield is what entitles the target
    /// to take over — and let the Dock drive. A failed follow (for example, when
    /// activation follow is disabled by the user) is reported to the caller; silently
    /// changing WindowServer state is not a safe fallback.
    private func switchDesktops(to destination: CGS.SpaceID,
                                windowID: CGWindowID,
                                pid: pid_t) async -> Bool {
        // Activation follow only fires when activating the application gives the Dock a
        // reason to switch. An application that already has a window on a Space the user
        // is looking at gives it none: the Dock treats the application as "present" and
        // the activation merely raises that nearby window — measured on Sublime Text,
        // four windows with one on the current desktop, where every click on an
        // off-desktop card activated in place and went nowhere. For that topology, skip
        // the doomed attempt (it fronts the wrong window during its 1.5 s wait) and go
        // straight to the route that works regardless of topology.
        if !hasWindowOnVisibleSpace(pid: pid) {
            _ = await AXCore.shared.designateMain(window: windowID, pid: pid)
            if let application = NSRunningApplication(processIdentifier: pid) {
                // An application that is already active receives no activation event,
                // and with no event the Dock has nothing to follow. Pulling activation
                // back to this process first (best effort) makes the yield a real change.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    NSApp.activate()
                }
                NSApp.yieldActivation(to: application)
                application.activate()
            }
            await Self.awaitSpace(destination, timeout: .milliseconds(1500))
            if CGS.isCurrent(space: destination) {
                return true
            }
        }

        // The desktop's own symbolic hotkey, posted with the hotkey temporarily
        // enabled: the Dock performs the same native slide the activation follow gets,
        // so a pinned application switches exactly as smoothly as an unpinned one.
        if await switchViaDesktopHotKey(to: destination) {
            return true
        }

        // Last resort — press the destination's button in Mission Control's Spaces Bar.
        // Fully Dock-managed and always available, but Mission Control is visible for a
        // moment, so it only runs when the hotkey route cannot serve (a desktop past 16,
        // or the SPI going away).
        return await switchViaMissionControl(to: destination)
    }

    /// Switches desktops through the system's "Switch to Desktop N" hotkey.
    ///
    /// The hotkey exists for every desktop whether or not the user has bound it; it is
    /// enabled just long enough to post its own key combination and then restored, so a
    /// user who keeps it disabled never sees it active. Unlike the Mission Control
    /// arrow keys, a numbered desktop hotkey accepts posted events — measured on this
    /// machine — and the Dock drives the full animated transition itself.
    private func switchViaDesktopHotKey(to destination: CGS.SpaceID) async -> Bool {
        guard let number = CGS.globalDesktopNumber(of: destination),
              let hotKey = CGS.desktopHotKeyID(forGlobalDesktop: number),
              let binding = CGS.symbolicHotKeyBinding(hotKey)
        else { return false }

        let wasEnabled = CGS.isSymbolicHotKeyEnabled(hotKey)
        if !wasEnabled { CGS.setSymbolicHotKey(hotKey, enabled: true) }
        defer { if !wasEnabled { CGS.setSymbolicHotKey(hotKey, enabled: false) } }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: binding.key, keyDown: true)
        down?.flags = binding.flags
        let up = CGEvent(keyboardEventSource: nil, virtualKey: binding.key, keyDown: false)
        up?.flags = binding.flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        await Self.awaitSpace(destination, timeout: .milliseconds(1200))
        return CGS.isCurrent(space: destination)
    }

    /// Whether the application owns a regular on-screen window on any Space the user is
    /// currently looking at — the topology that defeats activation follow.
    private func hasWindowOnVisibleSpace(pid: pid_t) -> Bool {
        let visible = CGS.currentSpaces()
        for window in CGS.applicationWindows(pid: pid) {
            guard window.layer == 0, window.isOnScreen,
                  window.frame.width >= 200, window.frame.height >= 200 else { continue }
            if CGS.spaces(forWindow: window.id).contains(where: { visible.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func switchViaMissionControl(to destination: CGS.SpaceID) async -> Bool {
        guard let target = Self.desktopPosition(of: destination) else { return false }

        let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        _ = try? await NSWorkspace.shared.openApplication(
            at: missionControl, configuration: NSWorkspace.OpenConfiguration())
        var presented = false
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(50))
            if MissionControlDetector.isActive { presented = true; break }
        }
        guard presented else { return false }
        // Let the entrance animation finish. A press during it nominally succeeds but
        // the Dock treats it as "leave Mission Control", exiting back to the desktop it
        // came from — measured: press returned success, Mission Control closed, and the
        // desktop never changed. The earlier standalone tool waited two seconds and
        // switched reliably; 600 ms is the shortest settle that held up in testing,
        // with one retry for slow frames.
        //
        // 600 ms measured as still too early — the press succeeded yet exited back to
        // the origin desktop. Two seconds is what the standalone tool that reliably
        // switched used; the backdrop this is timed from appears at the *start* of the
        // entrance animation, so most of this wait is the animation itself.
        try? await Task.sleep(for: .milliseconds(2000))

        let displayFrame = Self.displayFrame(forIdentifier: target.display)
        for _ in 0..<2 {
            let pressed = await AXCore.shared.pressMissionControlDesktopButton(
                number: target.number, within: displayFrame)
            if pressed {
                await Self.awaitSpace(destination, timeout: .milliseconds(900))
                if CGS.isCurrent(space: destination) { return true }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }

        // Nothing landed. If Mission Control is somehow still up, toggle it away rather
        // than stranding the user inside it.
        if MissionControlDetector.isActive {
            _ = try? await NSWorkspace.shared.openApplication(
                at: missionControl, configuration: NSWorkspace.OpenConfiguration())
        }
        return CGS.isCurrent(space: destination)
    }

    /// The user-visible position of a Space: its display and per-display desktop number.
    private static func desktopPosition(of space: CGS.SpaceID) -> (display: String, number: Int)? {
        for display in CGS.managedDisplaySpaces() {
            if let entry = display.spaces.first(where: { $0.id == space }), entry.type == 0 {
                return (display.displayIdentifier, entry.number)
            }
        }
        return nil
    }

    /// A display's frame in top-left-origin coordinates, resolved from the UUID string
    /// the Space topology uses.
    private static func displayFrame(forIdentifier identifier: String) -> CGRect? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            else { continue }
            if CFUUIDCreateString(nil, uuid) as String == identifier {
                return ScreenGeometry.accessibilityRect(fromAppKit: screen.frame)
            }
        }
        return nil
    }

    /// Polls until a Space is the one showing, or gives up.
    ///
    /// Bounded: if the switch does not take — it silently does not, for a Space on a
    /// display that has since been unplugged — the click still has to do something rather
    /// than hang on to the user's pointer.
    private static func awaitSpace(_ space: CGS.SpaceID,
                                   timeout: Duration = .milliseconds(1200)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return }
            if CGS.isCurrent(space: space) { return }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
    }

    private func raise(_ window: WindowInfo) async {
        let raised = await AXCore.shared.raise(window: window.id, pid: window.pid,
                                               fallbackActivate: false)
        guard !raised else { return }
        Log.dock.error("could not raise window \(window.id)")

        // The clicked window could not be reached at all. Before falling back to a bare
        // activation, go to a *real* window of the same application: activation is what
        // some applications answer by putting a window on whichever desktop is showing —
        // measured on Surge, whose dashboard lives on one desktop but appeared on the one
        // being looked at, untouchable in Mission Control because the surface it conjured
        // belongs to no Space. A placed sibling is something the user can actually be
        // taken to.
        //
        // Largest first: the application's principal window, not a stray dialog.
        let sibling = CGS.applicationWindows(pid: window.pid)
            .filter { candidate in
                candidate.id != window.id && candidate.layer == 0
                    && candidate.frame.width >= 200 && candidate.frame.height >= 200
                    && !CGS.spaces(forWindow: candidate.id).isEmpty
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

        if let sibling {
            if let destination = CGS.spaceToReach(window: sibling.id) {
                guard await switchDesktops(to: destination, windowID: sibling.id,
                                           pid: window.pid) else { return }
            }
            if await AXCore.shared.raise(window: sibling.id, pid: window.pid,
                                         fallbackActivate: false) {
                return
            }
        }

        // Nothing of this application is reachable as a window; bringing the process
        // forward is all that is left.
        _ = NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    /// Closes the bubble because another application came forward — unless it is the one
    /// a kept-open bubble has just raised a window of. See `expectedActivation`.
    private func applicationActivated(pid: pid_t?) {
        if let expected = expectedActivation, let pid,
           expected.pid == pid, Date() < expected.deadline {
            return
        }
        closeBubble()
    }

    /// Cancels everything driving an open bubble without touching the panel itself.
    private func cancelWork() {
        bubbleGeneration &+= 1
        expectedActivation = nil
        anchorSettleTask?.cancel()
        anchorSettleTask = nil
        activationTask?.cancel()
        activationTask = nil
        pendingTile = nil
        revealTask?.cancel()
        revealTask = nil
        cancelDismissal()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Closes a window and takes its preview away.
    ///
    /// The card is removed straight away rather than after the fact. `close` returns as
    /// soon as it has *pressed* the close button, but the window server takes a moment to
    /// retire the window, so re-reading the list immediately still finds it and the
    /// preview count never changed — close a window of two and both previews stayed.
    ///
    /// So: drop the card optimistically for instant feedback, wait for the window to
    /// actually disappear, then reconcile against reality. If the close did not take, the
    /// reconcile puts the card back rather than leaving a lie on screen.
    private func close(_ window: WindowInfo) {
        panelController.removeWindow(window.id)

        Task { [weak self] in
            let pressed = await AXCore.shared.close(window: window.id, pid: window.pid)
            if pressed, await Self.awaitDisappearance(of: window.id, pid: window.pid) {
                await WindowIndex.shared.noteClosed(window.id)
            }
            await self?.reloadActiveBubble()
        }
    }

    /// Waits, briefly, for a closed window to actually be gone, and says whether it went.
    ///
    /// Asks Accessibility rather than `CGWindowListCopyWindowInfo`, because a closed window
    /// never leaves the latter — measured on TextEdit, the entry outlives the window
    /// indefinitely, so polling it would spend the whole timeout and always conclude the
    /// close had failed.
    ///
    /// Returning `false` covers both "still there" and "could not tell", which is the
    /// conservative reading: a window that put up a save sheet has not closed, and neither
    /// answer should be recorded as a close.
    private static func awaitDisappearance(of id: CGWindowID, pid: pid_t,
                                           timeout: Duration = .milliseconds(700)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let live = await AXCore.shared.liveWindowIDs(pid: pid) else { return false }
            if !live.contains(id) { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return false
    }

    /// Closes every window in the open bubble.
    ///
    /// Deliberately not a loop of `close(_:)`: that reconciles after each one, so a bubble
    /// of six windows would rebuild itself six times and flicker through the sequence.
    /// The cards all go at once, then the app is asked to close each window, and the list
    /// is reconciled a single time at the end — which also puts back anything that refused
    /// to close, such as a document holding an unsaved-changes sheet.
    private func closeAll() {
        let windows = activeWindows
        guard !windows.isEmpty else { return }
        for window in windows { panelController.removeWindow(window.id) }

        Task { [weak self] in
            for window in windows {
                let pressed = await AXCore.shared.close(window: window.id, pid: window.pid)
                if pressed, await Self.awaitDisappearance(of: window.id, pid: window.pid) {
                    await WindowIndex.shared.noteClosed(window.id)
                }
            }
            await self?.reloadActiveBubble()
        }
    }

    /// Re-reads the window list for the open bubble, used after closing a window.
    private func reloadActiveBubble() async {
        guard let tile = activeTile else { return }
        await openBubble(for: tile, queryPurpose: .refreshedSnapshot)
    }

    private func startThumbnailCapture(for windows: [WindowInfo]) {
        thumbnailTask?.cancel()
        let width = panelController.thumbnailWidth
        let generation = bubbleGeneration
        thumbnailTask = Task { [weak self] in
            await ThumbnailEngine.shared.capture(windows, targetWidth: width) { id, thumbnail in
                Task { @MainActor in
                    guard self?.bubbleGeneration == generation else { return }
                    self?.panelController.apply(thumbnail: thumbnail, for: id)
                }
            }
        }
    }

    /// Re-captures on an interval so a playing video or a scrolling window stays current
    /// while the bubble is open.
    private func startPeriodicRefresh(for windows: [WindowInfo]) {
        refreshTask?.cancel()
        guard Preferences.shared.refreshThumbnailsEnabled else { return }

        let interval = max(0.2, Preferences.shared.refreshThumbnailsInterval)
        let width = panelController.thumbnailWidth
        let generation = bubbleGeneration
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                // Only on-screen windows can have changed; an off-Space or minimised one
                // would just re-capture the same pixels.
                let live = windows.filter(\.isOnScreen)
                guard !live.isEmpty else { continue }
                await ThumbnailEngine.shared.capture(live, targetWidth: width) { id, thumbnail in
                    Task { @MainActor in
                        guard self?.bubbleGeneration == generation else { return }
                        self?.panelController.apply(thumbnail: thumbnail, for: id)
                    }
                }
            }
        }
    }

    private func cancelDismissal() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }

    private func scheduleDismissal() {
        // Leaving the Dock must also cancel a hover that has not opened yet. Requiring a
        // visible panel before this cancellation let the delayed task open a bubble after
        // the pointer was already somewhere else.
        activationTask?.cancel()
        activationTask = nil
        pendingTile = nil
        guard panelController.isVisible, dismissalTask == nil else { return }

        let configured = Double(max(0, Preferences.shared.previewDeactivationDelay)) / 1000
        dismissalTask = Task { [weak self] in
            // One run-loop hop minimum so a pointer travelling diagonally from the icon
            // into the bubble is seen first — but no artificial floor beyond that, or a
            // user who set 0 to get an instant dismissal would not get one.
            if configured > 0 {
                try? await Task.sleep(for: .seconds(configured))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.closeBubble() }
        }
    }

    /// Closes a bubble the pointer has left without saying so.
    ///
    /// Dismissal normally rides on `mouseMoved`, and there are ordinary ways for the
    /// pointer to leave without one ever arriving: Mission Control taking over the screen,
    /// a Space switch, a hot corner, anything that warps the cursor. The bubble then stays
    /// put at `.popUpMenu` level — above every window, and accepting the clicks aimed at
    /// them. Measured by warping the pointer away, it sat there indefinitely.
    ///
    /// So the pointer is *polled* rather than waited for. Two consecutive misses, not one,
    /// because this must never race the hover-intent path that keeps a bubble alive while
    /// the user reaches diagonally into it.
    private func startPresenceWatchdog() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                guard let self, self.panelController.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                if self.dockStrip.contains(mouse) || self.panelController.contains(screenPoint: mouse) {
                    misses = 0
                    continue
                }
                misses += 1
                if misses >= 2 {
                    self.closeBubble()
                    return
                }
            }
        }
    }

    private func closeBubble() {
        presenceTask?.cancel()
        presenceTask = nil
        cancelWork()
        panelController.hide()
        activeTile = nil
        activeApplication = nil
        activeWindows = []
    }

    // MARK: - Keyboard navigation

    var isAcceptingKeys: Bool { panelController.isVisible }

    func handleKey(_ key: BubbleKey) -> Bool {
        guard panelController.isVisible else { return false }

        switch key {
        case .left, .up:
            panelController.moveFocus(by: -1)
        case .right, .down:
            panelController.moveFocus(by: 1)
        case .confirm:
            guard let window = panelController.focusedWindow else { return false }
            select(window)
        case .dismiss:
            closeBubble()
        case .closeWindow:
            guard let window = panelController.focusedWindow else { return false }
            close(window)
        }
        return true
    }

    // MARK: - Dock geometry

    /// Recomputes the strip the pointer must enter before the Dock is queried.
    ///
    /// The strip is deliberately generous along the Dock's edge: with auto-hide on the
    /// tiles sit entirely off screen — measured here at exactly one Dock height below the
    /// bottom — so the pointer has to be tracked into the reveal area before any tile can
    /// ever be hit.
    private func refreshDockGeometry() async {
        let tiles = await AXCore.shared.dockTiles()
        lastStripRefresh = Date()
        guard !tiles.isEmpty else { return }
        tileSnapshot = tiles

        let union = tiles.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull else { return }

        dockEdge = ScreenGeometry.dockEdge(forDockFrame: union)
        let strip = ScreenGeometry.appKitRect(fromAccessibility: union)

        // Anchor the strip to the SCREEN EDGE, not to where the Dock happens to be right
        // now. With auto-hide the Dock has two resting places — fully off screen and
        // fully on — and deriving the strip from the current one covers only that state.
        // Measured: computed while hidden, the strip ran from -120 to +6, so once the
        // Dock slid up to occupy 0…60 the pointer moving onto an icon fell *outside* the
        // gate and no further Dock queries ran at all. The bubble then only ever opened
        // for whichever icon happened to sit under the pointer at the screen edge.
        //
        // Spanning one Dock height outside the screen to two inside covers hidden,
        // revealed, and every frame of the animation between them.
        let screen = ScreenGeometry.screen(containing: CGPoint(x: strip.midX, y: strip.midY))
            ?? NSScreen.main
        guard let bounds = screen?.frame else { return }
        dockScreen = screen
        dockThickness = dockEdge.isHorizontal ? strip.height : strip.width
        dockStrip = Self.hoverStrip(forDock: strip, edge: dockEdge, screenFrame: bounds)
    }

    /// The gate rectangle for a Dock occupying `dock` (AppKit coordinates) along `edge`
    /// of a screen whose frame is `screenFrame`.
    ///
    /// The depth across the Dock is always its *thickness*: the height of a bottom Dock,
    /// the width of a side one. The left case once used the larger of the two sides —
    /// for a vertical Dock that is the whole column of icons, several hundred points —
    /// and started the strip that far outside the screen while keeping it only three
    /// Dock-widths wide, so the entire gate lay off screen. No pointer could ever enter
    /// it, and with the Dock on the left previews and Dock click shortcuts never worked.
    nonisolated static func hoverStrip(forDock dock: CGRect, edge: DockEdge,
                                       screenFrame bounds: CGRect) -> CGRect {
        switch edge {
        case .bottom:
            return CGRect(x: dock.minX - 40,
                          y: bounds.minY - dock.height,
                          width: dock.width + 80,
                          height: dock.height * 3)
        case .left:
            return CGRect(x: bounds.minX - dock.width,
                          y: dock.minY - 40,
                          width: dock.width * 3,
                          height: dock.height + 80)
        case .right:
            return CGRect(x: bounds.maxX - dock.width * 2,
                          y: dock.minY - 40,
                          width: dock.width * 3,
                          height: dock.height + 80)
        }
    }

    /// Whether a pointer on some screen is close enough to that screen's Dock edge to be
    /// pushing the Dock over to it. Two thicknesses deep, the same reach the hover strip
    /// has inside the screen; a Dock never measured yet is assumed 120 pt thick.
    nonisolated static func isNearDockEdge(_ point: CGPoint, of screenFrame: CGRect,
                                           edge: DockEdge, thickness: CGFloat) -> Bool {
        let reach = (thickness > 0 ? thickness : 120) * 2
        switch edge {
        case .bottom: return point.y <= screenFrame.minY + reach
        case .left: return point.x <= screenFrame.minX + reach
        case .right: return point.x >= screenFrame.maxX - reach
        }
    }

    private func runningApplication(for bundleURL: URL) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL == bundleURL }
    }
}
