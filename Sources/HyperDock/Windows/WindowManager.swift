import AppKit
import CoreGraphics

/// Receives keyboard input on behalf of an open preview bubble.
///
/// The bubble lives in a non-activating panel, so a non-frontmost agent app never gets
/// key events through the responder chain — they have to come from the event tap. This
/// protocol is the seam: `WindowManager` owns the tap and knows nothing about bubbles,
/// and only consumes keys while something is actually registered here.
@MainActor
protocol BubbleKeyboardHandling: AnyObject {
    var isAcceptingKeys: Bool { get }
    /// Returns true when the key was consumed.
    func handleKey(_ key: BubbleKey) -> Bool
}

enum BubbleKey: Sendable {
    case left, right, up, down
    case confirm
    case dismiss
    case closeWindow
}

/// Moving, resizing and snapping windows from anywhere on screen, plus keyboard input
/// for the preview bubble.
///
/// Driven by a `CGEventTap`, which carries one hard rule: **the callback must never
/// block.** It runs on the event delivery path, and the WindowServer disables any tap
/// that overruns — measured here, the budget is exactly 1.000 s. So the callback only
/// reads state it already has, decides whether to swallow the event, and hands real work
/// to an async task. It never makes an Accessibility call: that is a synchronous MIG RPC
/// into another process, and it is what crashed HyperDock 1.8.
///
/// The tap is attached to the main run loop, so the callback already runs on the main
/// actor and the small amount of state it touches needs no further synchronisation.
@MainActor
final class WindowManager {
    /// Every event the tap must receive. Kept as one contract so UI-supported inputs
    /// cannot be added to dispatch while silently omitted from registration.
    static let eventMask: CGEventMask =
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue) |
        (1 << CGEventType.leftMouseUp.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue) |
        (1 << CGEventType.otherMouseDown.rawValue) |
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.scrollWheel.rawValue)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let overlay = SnapOverlay()

    /// What the pointer is currently doing to a window.
    private enum Gesture {
        case none
        /// Waiting for the asynchronous hit test that identifies the grabbed window.
        case resolving(origin: CGPoint, mode: Mode)
        case active(window: AXCore.HitWindow, origin: CGPoint, startFrame: CGRect, mode: Mode)
        /// The mouse-down was swallowed but there turned out to be no window to drag.
        ///
        /// The rest of the press still has to be swallowed. The application underneath
        /// never saw the down, and handing it the drags and the up on their own gives it
        /// a release with no press — which some applications read as a click.
        case consumed
    }

    private enum Mode { case move, resize }

    private var gesture: Gesture = .none {
        didSet { restartWatchdog() }
    }

    /// Identifies one press, so a hit test that outlives its gesture cannot act on the
    /// next one. Without it, a press released before its hit test returned and followed by
    /// a second press had the *first* window attached to the second drag — and a failed
    /// first lookup ended the second gesture outright.
    private var gestureSerial: UInt = 0
    private var currentZone: SnapZone?
    private var zoneEnteredAt: Date?

    /// Clears a gesture that never saw its mouse-up.
    ///
    /// Several paths can lose the release — the tap being disabled mid-drag, a modal grab
    /// taking over, a fast user switch. A gesture stuck in `.resolving` or `.active`
    /// swallows every subsequent click, which would leave the machine feeling broken, so
    /// it is bounded by a timer rather than trusted.
    private var watchdog: Task<Void, Never>?

    /// Serialises the Accessibility writes a drag produces.
    ///
    /// One unstructured task per drag event would let writes land out of order on the
    /// cooperative pool and the window would visibly jitter backwards. Instead each drag
    /// event replaces a pending target and one worker applies the most recent one; the
    /// intermediate positions are worthless anyway.
    private var pendingFrame: CGRect?
    private var pendingTarget: (id: CGWindowID, pid: pid_t)?
    /// For a resize grabbed from the left or top, the edges that must not move. See
    /// `ResizeAnchor`.
    private var pendingAnchor: ResizeAnchor?
    private var frameWriter: Task<Void, Never>?

    /// Set while a preview bubble is open. Keys are only consumed while this is non-nil
    /// and accepting, so the user's real application keeps its arrow keys the rest of
    /// the time.
    weak var keyboardTarget: (any BubbleKeyboardHandling)?

    /// Called when a Dock icon is clicked with a bound modifier combination. Supplied by
    /// the coordinator that knows about Dock geometry, keeping this type free of it.
    var dockClickHandler: ((CGPoint, ModifierCombo, DockMouseButton) -> Bool)?

    /// Consulted for scrolls landing on the preview bubble, before the title-bar feature
    /// gets a look. Arguments: location, vertical delta, horizontal delta, and whether
    /// the event is momentum coasting rather than fingers. Returns true when the bubble
    /// dealt with it.
    var bubbleScrollHandler: ((CGPoint, Int64, Int64, Bool) -> Bool)?

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard Permissions.shared.hasAccessibility else { return false }

        // .cgSessionEventTap, not .cghidEventTap: the HID location requires root and
        // CGEvent.tapCreate simply returns nil without it.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()

                // Read the scalars here. `CGEvent` is not Sendable so it must not cross
                // into the actor-isolated call — and pulling only what is needed also
                // keeps the callback down to a few field reads, which is the point.
                let location = event.location
                let flags = event.flags
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let button = event.getIntegerValueField(.mouseEventButtonNumber)
                let scrollY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let scrollX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                // A trackpad reports continuous pixel deltas and leaves the line delta at
                // zero until a movement adds up to a whole notch. Reading only the line
                // axis therefore drops gentle two-finger flicks entirely.
                let scrollPointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
                let scrollPointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
                // Nonzero while the trackpad is coasting after the fingers have lifted.
                // Momentum events keep arriving for up to a second, which outlives any
                // reasonable throttle — a gesture handler that cannot see this field
                // re-fires on the tail of the very flick it already acted on.
                let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

                let swallow = MainActor.assumeIsolated {
                    manager.handle(type: type, location: location, flags: flags,
                                   keyCode: keyCode, buttonNumber: button,
                                   scrollX: scrollX, scrollY: scrollY,
                                   scrollPointY: scrollPointY, scrollPointX: scrollPointX,
                                   scrollMomentum: momentum)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.windows.error("could not create the event tap; Accessibility may have been revoked")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        scrollResolutionTask?.cancel()
        scrollResolutionTask = nil
        scrollingOverTitleBar = false
        endGesture()
    }

    // MARK: - Tap callback

    /// Decides whether to swallow an event. Must stay cheap: anything that could block
    /// belongs in a `Task`. Returns true to consume the event.
    private func handle(type: CGEventType,
                        location: CGPoint,
                        flags: CGEventFlags,
                        keyCode: Int64,
                        buttonNumber: Int64,
                        scrollX: Int64 = 0,
                        scrollY: Int64 = 0,
                        scrollPointY: Int64 = 0,
                        scrollPointX: Int64 = 0,
                        scrollMomentum: Int64 = 0) -> Bool {
        // The system disables a tap that overran its budget, and during secure input.
        // Re-enable rather than silently going deaf — and drop any in-flight gesture,
        // because its mouse-up was almost certainly among the events we missed.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            endGesture()
            return false
        }

        // The settings shortcut comes before the off switch. Advanced ▸ "Turn HyperDock
        // off" promises that this shortcut always works, and with the menu-bar icon
        // hidden it is the only way back to the switch that turns HyperDock on again.
        if type == .keyDown, Self.isSettingsHotKey(keyCode: keyCode, flags: flags) {
            openSettings()
            return true
        }

        let preferences = Preferences.shared
        guard !preferences.disabled else { return false }

        // While Mission Control is up, every event belongs to it. Intercepting anything —
        // a click that happens to fall where a Dock tile normally sits, a scroll over
        // where a title bar used to be — breaks selection inside Mission Control, and the
        // positions these checks are based on are meaningless while it is presented.
        if MissionControlDetector.isActive {
            endGesture()
            return false
        }

        switch type {
        case .keyDown:
            return handleKey(flags: flags, keyCode: keyCode)

        case .rightMouseDown, .otherMouseDown:
            guard let button = DockMouseButton(eventType: type, buttonNumber: buttonNumber) else {
                return false
            }
            return dockClickHandler?(location, ModifierCombo(eventFlags: flags), button) ?? false

        case .leftMouseDown:
            if dockClickHandler?(location, ModifierCombo(eventFlags: flags), .left) == true {
                return true
            }
            guard let mode = dragMode(for: flags, preferences: preferences) else { return false }
            // Only the location is recorded here; identifying the window under it needs
            // Accessibility, which must not run on this thread.
            gestureSerial &+= 1
            gesture = .resolving(origin: location, mode: mode)
            resolveWindow(at: location, mode: mode, serial: gestureSerial)
            return true

        case .leftMouseDragged:
            switch gesture {
            case .none:
                return false
            case .resolving, .consumed:
                // Swallow while the hit test is in flight, so the application underneath
                // does not begin its own drag beneath ours — and after a hit test that
                // found nothing, because the press it would belong to was never delivered.
                return true
            case .active(let window, let origin, let startFrame, let mode):
                applyDrag(window: window, origin: origin, startFrame: startFrame,
                          mode: mode, current: location)
                return true
            }

        case .leftMouseUp:
            if case .none = gesture { return false }
            finishGesture()
            return true

        case .scrollWheel:
            // The bubble is asked first. A scroll over it belongs to the bubble whether or
            // not it acts on it — letting it fall through would scroll whatever window
            // happens to lie underneath, which is never what the pointer is aimed at.
            let vertical = scrollY != 0 ? scrollY : scrollPointY
            let horizontal = scrollX != 0 ? scrollX : scrollPointX
            if bubbleScrollHandler?(location, vertical, horizontal, scrollMomentum != 0) == true {
                return true
            }
            return handleScroll(at: location, deltaX: scrollX, deltaY: scrollY)

        default:
            return false
        }
    }

    // MARK: - Gesture handling

    /// Whether some press can start a move drag at all — the gesture edge snapping rides on.
    ///
    /// Mirrors `dragMode(for:preferences:)`: resize is matched first, so a move combination
    /// equal to an enabled resize combination can never be reached.
    static func isMoveDragReachable(moveEnabled: Bool,
                                    moveModifiers: ModifierCombo,
                                    resizeEnabled: Bool,
                                    resizeModifiers: ModifierCombo) -> Bool {
        guard moveEnabled, !moveModifiers.isEmpty else { return false }
        return !(resizeEnabled && resizeModifiers == moveModifiers)
    }

    private func dragMode(for flags: CGEventFlags, preferences: Preferences) -> Mode? {
        let pressed = ModifierCombo(eventFlags: flags)
        // Resize is checked first: its combination is usually a superset of move's, so
        // testing move first would always win and resize would be unreachable.
        if preferences.resizeWindowsEnabled, !preferences.resizeWindowsModifiers.isEmpty,
           pressed == preferences.resizeWindowsModifiers {
            return .resize
        }
        if preferences.moveWindowsEnabled, !preferences.moveWindowsModifiers.isEmpty,
           pressed == preferences.moveWindowsModifiers {
            return .move
        }
        return nil
    }

    private func resolveWindow(at origin: CGPoint, mode: Mode, serial: UInt) {
        Task { [weak self] in
            let hit = await AXCore.shared.window(at: origin)
            await MainActor.run {
                guard let self else { return }
                // A mouse-up may have already landed while the hit test was running, and
                // another press may have begun since; either way this answer is stale.
                guard serial == self.gestureSerial, case .resolving = self.gesture else { return }
                guard let hit else {
                    self.gesture = .consumed
                    return
                }
                self.gesture = .active(window: hit, origin: origin,
                                       startFrame: hit.frame, mode: mode)
            }
        }
    }

    private func applyDrag(window: AXCore.HitWindow,
                           origin: CGPoint,
                           startFrame: CGRect,
                           mode: Mode,
                           current: CGPoint) {
        let dx = current.x - origin.x
        let dy = current.y - origin.y

        var target = startFrame
        var anchor: ResizeAnchor?
        switch mode {
        case .move:
            target.origin.x += dx
            target.origin.y += dy

        case .resize:
            (target, anchor) = Self.resizedFrame(
                from: startFrame, grabbedAt: origin, dx: dx, dy: dy,
                minimum: CGSize(width: 120, height: 80))
        }

        enqueueFrame(target, anchor: anchor, for: window)

        guard mode == .move, Preferences.shared.snapOnDragToEdge else { return }
        updateSnapPreview(pointer: current)
    }

    /// The edges a resize grabbed from the left or the top must keep where they are.
    ///
    /// Growing from the left is written as "move the origin, change the width", and that
    /// is only right if the application accepts the width. One with a minimum size answers
    /// a narrower request with its minimum while keeping the new origin, so the right edge
    /// — which the user never touched — slid right by the difference, and kept sliding on
    /// every drag event past the minimum.
    nonisolated struct ResizeAnchor: Equatable {
        /// The right edge to hold, when the left edge is the one being dragged.
        var maxX: CGFloat?
        /// The bottom edge to hold (Accessibility y grows downward), when the top is.
        var maxY: CGFloat?
    }

    /// The frame a resize drag asks for, and which edges it must hold.
    ///
    /// Resize from the quadrant the user grabbed, so the opposite corner stays put.
    /// Growing only from the top-left — as a naive implementation does — means every drag
    /// behaves as if the bottom-right corner were grabbed, which fights the user whenever
    /// they started anywhere else.
    nonisolated static func resizedFrame(from startFrame: CGRect,
                                         grabbedAt origin: CGPoint,
                                         dx: CGFloat, dy: CGFloat,
                                         minimum: CGSize) -> (CGRect, ResizeAnchor?) {
        var target = startFrame
        var anchor = ResizeAnchor()
        let grabbedRight = origin.x > startFrame.midX
        let grabbedBottom = origin.y > startFrame.midY

        if grabbedRight {
            target.size.width = max(minimum.width, startFrame.width + dx)
        } else {
            let width = max(minimum.width, startFrame.width - dx)
            target.origin.x = startFrame.maxX - width
            target.size.width = width
            anchor.maxX = startFrame.maxX
        }
        // Accessibility y grows downward, so "bottom" is the larger y.
        if grabbedBottom {
            target.size.height = max(minimum.height, startFrame.height + dy)
        } else {
            let height = max(minimum.height, startFrame.height - dy)
            target.origin.y = startFrame.maxY - height
            target.size.height = height
            anchor.maxY = startFrame.maxY
        }
        return (target, anchor == ResizeAnchor() ? nil : anchor)
    }

    /// Where a window has to go so the held edges stay put at the size it actually took.
    nonisolated static func reanchored(_ applied: CGRect, to anchor: ResizeAnchor) -> CGRect {
        var frame = applied
        if let maxX = anchor.maxX { frame.origin.x = maxX - applied.width }
        if let maxY = anchor.maxY { frame.origin.y = maxY - applied.height }
        return frame
    }

    /// Coalesces frame writes so only the latest target is ever applied.
    private func enqueueFrame(_ frame: CGRect, anchor: ResizeAnchor? = nil,
                              for window: AXCore.HitWindow) {
        pendingFrame = frame
        pendingAnchor = anchor
        pendingTarget = (window.id, window.pid)
        guard frameWriter == nil else { return }

        frameWriter = Task { [weak self] in
            while true {
                // A writer cancelled by `endGesture` must stop here, and must not touch
                // `frameWriter` on the way out: by the time its last write returns, the
                // next gesture may have started a writer of its own, and clearing the
                // reference to it let a third writer start alongside — two loops applying
                // frames concurrently, landing out of order.
                guard !Task.isCancelled, let self else { return }
                guard let frame = self.pendingFrame, let target = self.pendingTarget else {
                    self.frameWriter = nil
                    return
                }
                let anchor = self.pendingAnchor
                self.pendingFrame = nil
                self.pendingAnchor = nil
                let applied = await AXCore.shared.setFrame(frame, window: target.id,
                                                           pid: target.pid)
                guard !Task.isCancelled else { return }
                // The application chose a different size — a minimum, or a terminal
                // rounding to whole character cells — so put the held edges back where the
                // user left them. Not remembered as a floor: a size rounded up to a cell is
                // no lower bound, and treating it as one stopped such a window shrinking.
                // A newer drag event supersedes the correction, since it is written next.
                guard let anchor, let applied, self.pendingFrame == nil,
                      abs(applied.width - frame.width) > 0.5
                        || abs(applied.height - frame.height) > 0.5
                else { continue }
                let corrected = Self.reanchored(applied, to: anchor)
                if corrected.origin != applied.origin {
                    await AXCore.shared.setFrame(corrected, window: target.id, pid: target.pid)
                }
            }
        }
    }

    /// Tracks which snap zone the pointer is in, honouring the two configured delays.
    ///
    /// Driven by a timer rather than only by drag events: a user who moves to the edge
    /// and then holds perfectly still generates no further events, and a delay that only
    /// advanced on movement would never elapse for them.
    private var zoneTimer: Timer?

    private func updateSnapPreview(pointer: CGPoint) {
        let appKitPoint = ScreenGeometry.appKitPoint(fromAccessibility: pointer)
        guard let screen = ScreenGeometry.screen(containing: appKitPoint),
              let zone = SnapZone.zone(forPointerAt: appKitPoint, in: screen) else {
            clearZone()
            return
        }

        if zone != currentZone {
            currentZone = zone
            zoneEnteredAt = Date()
            overlay.hide()
            scheduleZoneCheck(zone: zone, screen: screen, pointer: appKitPoint)
            return
        }
        evaluateZone(zone: zone, screen: screen, pointer: appKitPoint)
    }

    private func scheduleZoneCheck(zone: SnapZone, screen: NSScreen, pointer: CGPoint) {
        zoneTimer?.invalidate()
        let required = requiredDelay(pointer: pointer, screen: screen)
        // Resolve the rect now: `NSScreen` is not Sendable and must not be captured into
        // the timer's closure, whereas a `CGRect` crosses freely.
        let destination = zone.frame(in: screen)
        zoneTimer = Timer.scheduledTimer(withTimeInterval: required + 0.01, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentZone == zone else { return }
                self.overlay.show(at: destination)
            }
        }
    }

    private func evaluateZone(zone: SnapZone, screen: NSScreen, pointer: CGPoint) {
        guard let entered = zoneEnteredAt else { return }
        let required = requiredDelay(pointer: pointer, screen: screen)
        guard Date().timeIntervalSince(entered) >= required else { return }
        overlay.show(at: zone.frame(in: screen))
    }

    /// Two delays, as the original has: a longer one for merely being near the border,
    /// and a shorter one for sitting exactly on it.
    private func requiredDelay(pointer: CGPoint, screen: NSScreen) -> TimeInterval {
        let area = screen.frame
        let onExactBorder = pointer.x <= area.minX + 1 || pointer.x >= area.maxX - 1
            || pointer.y <= area.minY + 1 || pointer.y >= area.maxY - 1
        return onExactBorder
            ? Preferences.shared.snapDelayExactBorder
            : Preferences.shared.snapDelayNearBorder
    }

    private func clearZone() {
        currentZone = nil
        zoneEnteredAt = nil
        zoneTimer?.invalidate()
        zoneTimer = nil
        overlay.hide()
    }

    private func finishGesture() {
        let snapping: (AXCore.HitWindow, SnapZone)?
        if case .active(let window, _, _, .move) = gesture,
           overlay.isVisible, let zone = currentZone {
            snapping = (window, zone)
        } else {
            snapping = nil
        }

        endGesture()

        guard let (window, zone) = snapping else { return }
        // NSEvent.mouseLocation is already in AppKit's bottom-left space, so it must not
        // be run through the Accessibility conversion — doing so mirrors an already
        // correct value and lands the window on the wrong display.
        guard let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation) else { return }
        let target = ScreenGeometry.accessibilityRect(fromAppKit: zone.frame(in: screen))
        Task { await AXCore.shared.setFrame(target, window: window.id, pid: window.pid) }
    }

    /// The single teardown path, so no field is ever left behind.
    private func endGesture() {
        gesture = .none
        pendingFrame = nil
        pendingTarget = nil
        pendingAnchor = nil
        frameWriter?.cancel()
        frameWriter = nil
        watchdog?.cancel()
        watchdog = nil
        clearZone()
    }

    /// Arms the stuck-gesture timer.
    ///
    /// It asks the hardware before giving up on a gesture. A plain ten-second timeout also
    /// fired on a drag that was simply long — a window being nudged into place, or held
    /// still while the user decided — and cut it off mid-air: the window stopped following
    /// the pointer, and the rest of the press, whose down had been swallowed, went to the
    /// application underneath as drags and a release it never saw begin. A button that is
    /// still physically down means the release has not been lost, so the gesture is fine.
    private func restartWatchdog() {
        watchdog?.cancel()
        guard !isIdle else { watchdog = nil; return }
        watchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                guard let self, !self.isIdle else { return }
                if CGEventSource.buttonState(.combinedSessionState, button: .left) {
                    continue
                }
                Log.windows.error("gesture watchdog fired; releasing a stuck drag")
                self.endGesture()
                return
            }
        }
    }

    private var isIdle: Bool {
        if case .none = gesture { return true }
        return false
    }

    // MARK: - Keyboard

    /// Returns true when the key was consumed.
    private func handleKey(flags: CGEventFlags, keyCode: Int64) -> Bool {
        // The settings shortcut has already been handled by `handle`, ahead of the
        // disabled check.
        //
        // Bubble navigation first, and only while a bubble is genuinely open. The target
        // is a weak reference, so a torn-down bubble releases these keys automatically.
        if let target = keyboardTarget, target.isAcceptingKeys,
           let key = Self.bubbleKey(keyCode: keyCode, flags: flags),
           target.handleKey(key) {
            return true
        }

        let preferences = Preferences.shared
        guard preferences.keyboardSnapEnabled, !preferences.keyboardSnapModifiers.isEmpty else {
            return false
        }

        // Arrow keys and the numeric keypad both carry maskNumericPad, and arrows also
        // carry maskSecondaryFn on built-in keyboards. Comparing raw flags for equality
        // therefore never matches the configured combo — these bits have to be ignored.
        let pressed = ModifierCombo(eventFlags: flags)
        guard pressed == preferences.keyboardSnapModifiers else { return false }

        // G for grid: halves and quarters run out at three windows, and this is the same
        // gesture family, so it belongs on the same modifiers.
        if keyCode == 5 {
            Task { @MainActor in
                guard let front = NSWorkspace.shared.frontmostApplication else { return }
                WindowActions.tileWindows(of: front)
            }
            return true
        }

        guard let zone = SnapZone.zone(forKeyCode: keyCode) else { return false }
        Task { await snapFrontmostWindow(to: zone) }
        return true
    }

    private func openSettings() {
        // Off the delivery path: building the settings window the first time means
        // instantiating a SwiftUI hierarchy, and the tap has a one-second budget for the
        // whole callback.
        Task { @MainActor in
            SettingsWindowController.shared.show(selecting: .general)
        }
    }

    /// The one shortcut that works with no bubble open and HyperDock in the background.
    private static func isSettingsHotKey(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let preferences = Preferences.shared
        guard preferences.settingsHotKeyEnabled,
              !preferences.settingsHotKeyModifiers.isEmpty,
              keyCode == 4 /* h */ else { return false }
        return ModifierCombo(eventFlags: flags) == preferences.settingsHotKeyModifiers
    }

    static func bubbleKey(keyCode: Int64, flags: CGEventFlags) -> BubbleKey? {
        let combo = ModifierCombo(eventFlags: flags)
        switch keyCode {
        case 123 where combo.isEmpty: return .left
        case 124 where combo.isEmpty: return .right
        case 126 where combo.isEmpty: return .up
        case 125 where combo.isEmpty: return .down
        // Each pattern needs its own `where`: written `case 36, 76 where combo.isEmpty`
        // the condition binds only to the last one, so a *modified* Return was taken as
        // a confirm and swallowed while the bubble was open.
        case 36 where combo.isEmpty, 76 where combo.isEmpty: return .confirm
        // Unmodified only, like the rest: ⌘⌥Esc is Force Quit, and swallowing it while a
        // bubble was open took away the way out of a hung application.
        case 53 where combo.isEmpty: return .dismiss       // Escape
        case 13 where combo == [.command]: return .closeWindow  // Cmd-W
        default: return nil
        }
    }

    // MARK: - Title-bar scrolling

    /// Throttles scroll handling: a trackpad emits a burst of events per gesture and
    /// each one would otherwise fire a separate snap or Space change.
    private var lastScroll: Date = .distantPast
    private var scrollResolutionTask: Task<Void, Never>?

    /// Scrolling on a window's title bar snaps it (vertical) or moves it between Spaces
    /// (horizontal).
    ///
    /// Only the title bar, so scrolling inside a document is untouched: the strip is
    /// resolved from the window's own frame, and the event is passed straight through
    /// whenever the pointer is anywhere else.
    private func handleScroll(at location: CGPoint, deltaX: Int64, deltaY: Int64) -> Bool {
        guard Preferences.shared.scrollTitlebarEnabled else { return false }
        guard abs(deltaX) + abs(deltaY) > 0 else { return false }
        guard Date().timeIntervalSince(lastScroll) > 0.4 else {
            // Swallow the tail of a gesture already acted on, or the window would snap
            // repeatedly from one flick.
            return scrollingOverTitleBar
        }

        // The first event starts an AX hit test. A trackpad can deliver several more
        // before it finishes; they must not each launch a second snap operation.
        guard scrollResolutionTask == nil else { return scrollingOverTitleBar }

        // A new gesture starts with no answer yet. The flag still held the previous
        // gesture's — true after any title-bar scroll — so the first event of the next
        // scroll anywhere, a document included, was swallowed on the strength of a title
        // bar the pointer had long since left.
        scrollingOverTitleBar = false

        // Resolving the window needs Accessibility, which must not run here. Kick it to
        // a task and let this event through; the *next* event in the gesture is caught by
        // the throttle above once `scrollingOverTitleBar` is known.
        scrollResolutionTask = Task { [weak self] in
            defer { self?.scrollResolutionTask = nil }
            guard let hit = await AXCore.shared.window(at: location) else {
                guard !Task.isCancelled else { return }
                self?.scrollingOverTitleBar = false
                return
            }
            guard !Task.isCancelled else { return }
            // The title bar is the top ~28 pt of the window, in Accessibility's
            // top-left-origin space.
            let titleBar = CGRect(x: hit.frame.minX, y: hit.frame.minY,
                                  width: hit.frame.width, height: 28)
            guard titleBar.contains(location) else {
                self?.scrollingOverTitleBar = false
                return
            }
            self?.scrollingOverTitleBar = true
            self?.lastScroll = Date()
            await self?.applyScroll(to: hit, deltaX: deltaX, deltaY: deltaY)
        }
        return scrollingOverTitleBar
    }

    private var scrollingOverTitleBar = false

    /// Scrolling a title bar snaps the window.
    ///
    /// A sideways flick used to send the window to the neighbouring Space. It cannot: on
    /// macOS 26 an unprivileged process cannot move another application's window between
    /// Spaces at all. Measured against a TextEdit window, three routes were tried and all
    /// three left it exactly where it was — `CGSMoveWindowsToManagedSpace` on our own
    /// connection and on the owning application's (obtained via `CGSGetConnectionIDForPSN`,
    /// which resolved correctly), and `CGSSetWindowListWorkspace`, which at least had the
    /// decency to return error 1006. The first two return `void`, so nothing could tell
    /// the gesture it had failed and it silently did nothing.
    ///
    /// Sideways therefore snaps to the left or right half, which pairs with up and down
    /// maximising and restoring, and — unlike the Space move — actually happens.
    private func applyScroll(to hit: AXCore.HitWindow, deltaX: Int64, deltaY: Int64) async {
        // Horizontal wins when the gesture is clearly sideways, so a diagonal flick does
        // not do both.
        let zone: SnapZone
        if abs(deltaX) > abs(deltaY) {
            zone = deltaX < 0 ? .right : .left
        } else {
            zone = deltaY > 0 ? .maximize : .centre
        }

        guard let screen = ScreenGeometry.screen(
            containing: ScreenGeometry.appKitPoint(fromAccessibility: hit.frame.origin))
        else { return }
        let target = ScreenGeometry.accessibilityRect(fromAppKit: zone.frame(in: screen))
        await AXCore.shared.setFrame(target, window: hit.id, pid: hit.pid)
    }

    /// The last zone a keyboard snap put a window in, so a repeated press can be told
    /// apart from a first one. Geometry alone cannot always tell: an application with a
    /// minimum size answers a half-screen request with whatever it will tolerate, and its
    /// frame never matches the zone it is logically occupying.
    private var lastKeyboardSnap: (window: CGWindowID, zone: SnapZone,
                                   screenFrame: CGRect, landedFrame: CGRect)?

    /// Whether a window already sits in a zone on a screen — by geometry, or by this
    /// being exactly where the previous keyboard snap put it.
    private func occupies(_ zone: SnapZone, on screen: NSScreen, frame: CGRect,
                          window: CGWindowID) -> Bool {
        let zoneFrame = ScreenGeometry.accessibilityRect(fromAppKit: zone.frame(in: screen))
        let tolerance: CGFloat = 16
        if abs(frame.minX - zoneFrame.minX) <= tolerance,
           abs(frame.minY - zoneFrame.minY) <= tolerance,
           abs(frame.width - zoneFrame.width) <= tolerance,
           abs(frame.height - zoneFrame.height) <= tolerance {
            return true
        }
        // The memory is only trusted while the window is still where the snap left it.
        // Without the frame check, a window snapped and then dragged away by hand would
        // still "occupy" its old zone, and the next press would cross displays instead
        // of snapping in place.
        if let last = lastKeyboardSnap,
           last.window == window, last.zone == zone, last.screenFrame == screen.frame,
           abs(frame.minX - last.landedFrame.minX) <= 24,
           abs(frame.minY - last.landedFrame.minY) <= 24 {
            return true
        }
        return false
    }

    private func snapFrontmostWindow(to zone: SnapZone) async {
        // The focused window, not the one under the pointer. Keyboard commands must not
        // depend on where the mouse happens to be — and after the first snap the window
        // has moved out from under a stationary pointer, so a pointer-based lookup makes
        // every subsequent press a no-op.
        guard let hit = await AXCore.shared.focusedWindow(), !hit.frame.isEmpty else { return }

        // Snap within the display the window is actually on, so a window on a secondary
        // screen stays there instead of jumping to wherever the pointer is.
        let centre = ScreenGeometry.appKitPoint(
            fromAccessibility: CGPoint(x: hit.frame.midX, y: hit.frame.midY))
        guard let screen = ScreenGeometry.screen(containing: centre) else { return }

        // Crossing displays. Pressing toward an edge whose zone the window already
        // occupies walks it onto the neighbouring display in that direction, entering
        // through the opposite edge — so a repeated ⌃⌥→ carries a window right across
        // the desktop in half-screen steps. At the desktop's edge the press re-snaps in
        // place, which is a visible no-op rather than a wrap: wrapping would mean the
        // same keystroke sometimes moves a window one display and sometimes three back.
        var targetScreen = screen
        var targetZone = zone
        if let direction = zone.cardinalDirection,
           occupies(zone, on: screen, frame: hit.frame, window: hit.id),
           let neighbour = ScreenGeometry.screen(direction, of: screen) {
            targetScreen = neighbour
            targetZone = zone.continuationZone
        }

        // Every dimension comes from the live `visibleFrame`, so resolution changes,
        // display arrangement, the menu bar and a non-hidden Dock are all accounted for
        // without anything being assumed.
        let area = targetScreen.visibleFrame
        let target = ScreenGeometry.accessibilityRect(
            fromAppKit: targetZone.frame(in: targetScreen))
        // Addressed by "the focused window of this application", not by window id: the id
        // route goes through `kAXWindowsAttribute`, which several applications under-report
        // badly enough that the snap silently did nothing for all but one of their windows.
        let applied = await AXCore.shared.setFrameOnFocusedWindow(target, pid: hit.pid)

        // Nothing moved — and a memory of a snap that never happened would send the next
        // press across a display boundary while the window sits untouched.
        guard let applied else { return }

        // Setting a size is advisory: an application with a minimum size returns a larger
        // window than asked for — Surge, for instance, answers a request for 2056×645
        // with 1029×672. When that happens the origin computed for the *requested* size
        // pushes the window off screen, so nudge it back inside using the size the
        // application actually accepted.
        var landed = applied
        if applied.size != target.size {
            let appliedAppKit = ScreenGeometry.appKitRect(fromAccessibility: applied)
            var corrected = appliedAppKit
            corrected.origin.x = min(max(appliedAppKit.minX, area.minX),
                                     area.maxX - appliedAppKit.width)
            corrected.origin.y = min(max(appliedAppKit.minY, area.minY),
                                     area.maxY - appliedAppKit.height)
            if corrected.origin != appliedAppKit.origin {
                landed = ScreenGeometry.accessibilityRect(fromAppKit: corrected)
                await AXCore.shared.setFrame(landed, window: hit.id, pid: hit.pid)
            }
        }
        lastKeyboardSnap = (hit.id, targetZone, targetScreen.frame, landed)
    }
}

extension ModifierCombo {
    /// Builds a combination from a tap event's flags.
    ///
    /// Deliberately ignores caps-lock, the numeric-keypad bit and the secondary-fn bit:
    /// arrow keys and keypad keys set those on their own, so including them would make an
    /// exact match against a user-configured combination impossible.
    init(eventFlags: CGEventFlags) {
        var combo = ModifierCombo()
        if eventFlags.contains(.maskControl) { combo.insert(.control) }
        if eventFlags.contains(.maskAlternate) { combo.insert(.option) }
        if eventFlags.contains(.maskCommand) { combo.insert(.command) }
        if eventFlags.contains(.maskShift) { combo.insert(.shift) }
        self = combo
    }
}
