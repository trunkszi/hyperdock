import AppKit
import Observation
import SwiftUI

/// State backing the preview bubble, and the geometry maths that sizes it.
@MainActor
@Observable
final class BubbleModel {
    var windows: [WindowInfo] = []
    var applicationName: String = ""
    var thumbnails: [CGWindowID: Thumbnail] = [:]
    var edge: DockEdge = .bottom
    var pointerPosition: CGFloat = 0
    var snapScale: CGFloat = 1

    /// The preview under the pointer.
    var hoveredWindow: CGWindowID? {
        didSet { onFocusChange?() }
    }

    /// Fired whenever the focused preview changes, so the full-size preview can follow.
    var onFocusChange: (() -> Void)?
    /// The preview selected with the keyboard. Independent of hover so the two do not
    /// fight: whichever the user last used wins, and moving the mouse takes over again.
    var keyboardFocusIndex: Int? {
        didSet { onFocusChange?() }
    }

    var onSelect: (WindowInfo) -> Void = { _ in }
    var onClose: (WindowInfo) -> Void = { _ in }
    var onNewWindow: () -> Void = {}
    var onMinimizeAll: () -> Void = {}
    var onCloseAll: () -> Void = {}
    var onTileAll: () -> Void = {}

    /// Which preview currently reads as focused, from either input.
    var focusedWindowID: CGWindowID? {
        if let index = keyboardFocusIndex, windows.indices.contains(index) {
            return windows[index].id
        }
        return hoveredWindow
    }

    var focusedWindow: WindowInfo? {
        guard let id = focusedWindowID else { return nil }
        return windows.first { $0.id == id }
    }

    /// Moves keyboard focus, wrapping at both ends so holding an arrow key cycles.
    func moveFocus(by delta: Int) {
        guard !windows.isEmpty else { return }
        let current: Int
        if let index = keyboardFocusIndex {
            current = index
        } else if let hovered = hoveredWindow,
                  let index = windows.firstIndex(where: { $0.id == hovered }) {
            // Picking up from the hovered tile means the first arrow press continues
            // from where the user is already looking.
            current = index
        } else {
            current = delta > 0 ? -1 : 0
        }
        let count = windows.count
        keyboardFocusIndex = ((current + delta) % count + count) % count
    }

    // MARK: - Metrics

    /// Layout numbers derived from the bubble-size slider and the previews-per-row
    /// setting, kept in one place so the panel and the view agree on the size.
    struct Metrics {
        let size: CGSize
        let thumbnailWidth: CGFloat
        let columns: Int
    }

    /// The largest size the whole bubble may take, set by the panel from the visible
    /// frame of the screen it is about to appear on. `nil` means unbounded.
    ///
    /// Without it the bubble's size followed only from the window count and the slider,
    /// so an application with many windows — or a large slider on a small display — grew
    /// a bubble taller or wider than the screen, and the on-screen clamp could only push
    /// the overflow off the opposite edge. The bubble has no scrolling, so whatever fell
    /// off was simply unreachable.
    var sizeLimit: CGSize?

    /// The thumbnail width the slider currently asks for, shrunk if needed so the whole
    /// bubble fits inside `sizeLimit`.
    ///
    /// The slider's floor is deliberately generous: below roughly 140pt a window
    /// screenshot stops being recognisable, which defeats the point of a visual switcher.
    /// Fitting the screen still wins over that floor, because an unreachable preview is
    /// worse than a small one.
    var thumbnailWidth: CGFloat {
        let slider = Preferences.shared.bubbleSize
        let preferred = 140 + slider * 220   // 140…360 pt
        guard let sizeLimit, !windows.isEmpty else { return preferred }
        let columns = columnCount
        return Self.fittedThumbnailWidth(
            preferred: preferred,
            columns: columns,
            rows: max(1, Int(ceil(Double(windows.count) / Double(columns)))),
            aspectRatio: representativeAspectRatio,
            chrome: chromeSize(for: edge),
            limit: sizeLimit)
    }

    /// Tile height for the current window set, driven by the mean aspect ratio so tiles
    /// in a row share a baseline instead of jittering.
    var thumbnailHeight: CGFloat {
        (thumbnailWidth / representativeAspectRatio).rounded()
    }

    private var representativeAspectRatio: CGFloat {
        let ratios = windows.map(\.aspectRatio).filter { $0 > 0 }
        let representative = ratios.isEmpty
            ? 16.0 / 10.0
            : ratios.reduce(0, +) / CGFloat(ratios.count)
        // Clamped so a very tall or very wide window cannot stretch the whole row into
        // an unusable shape.
        return min(max(representative, 0.8), 2.4)
    }

    /// Everything in the bubble that is not thumbnail: padding, the header and the
    /// pointer. Shared by `metrics(for:)` and the fit so the two cannot disagree.
    private func chromeSize(for edge: DockEdge) -> CGSize {
        var size = CGSize(width: Design.bubblePadding * 2, height: Design.bubblePadding * 2)
        if Preferences.shared.showApplicationName {
            size.height += Design.headerHeight + Design.titleGap
        }
        if Preferences.shared.drawTriangle {
            switch edge {
            case .bottom: size.height += Design.pointerLength
            case .left, .right: size.width += Design.pointerLength
            }
        }
        return size
    }

    /// The widest thumbnail, up to `preferred`, at which a grid of `columns` × `rows`
    /// previews plus `chrome` still fits inside `limit`.
    ///
    /// Floored at 40 pt: a limit too small for even that is a degenerate screen, and a
    /// zero or negative width would collapse the grid instead of merely overflowing.
    static func fittedThumbnailWidth(preferred: CGFloat,
                                     columns: Int,
                                     rows: Int,
                                     aspectRatio: CGFloat,
                                     chrome: CGSize,
                                     limit: CGSize) -> CGFloat {
        let columns = CGFloat(max(1, columns))
        let rows = CGFloat(max(1, rows))
        let byWidth = (limit.width - chrome.width - (columns - 1) * Design.cardGap) / columns
        let rowHeight = (limit.height - chrome.height - (rows - 1) * Design.cardGap) / rows
        // Each row is a thumbnail plus its title line; the thumbnail's height is its width
        // over the aspect ratio, so the height budget converts back into a width. The
        // `rounded()` in `thumbnailHeight` can add half a point per row, hence the 1 pt.
        let byHeight = (rowHeight - Design.titleGap - Design.titleHeight - 1) * aspectRatio
        return max(40, min(preferred, byWidth, byHeight).rounded(.down))
    }

    /// Columns to lay the previews out in.
    ///
    /// The user's "previews per row" is a *maximum*, not a target. Filling each row to
    /// the limit leaves the last row nearly empty — six windows at a limit of five gives
    /// a row of five and a row of one, a wide bubble with a large hole in it. Spreading
    /// the same windows evenly across the rows they need (three and three) is both
    /// tidier and a smaller pointer journey.
    var columnCount: Int {
        let limit = max(1, Preferences.shared.previewsPerRow)
        let count = windows.count
        guard count > 0 else { return 1 }
        let rows = Int(ceil(Double(count) / Double(limit)))
        return Int(ceil(Double(count) / Double(max(1, rows))))
    }

    func metrics(for edge: DockEdge) -> Metrics {
        let columns = columnCount
        let rows = max(1, Int(ceil(Double(windows.count) / Double(columns))))

        let chrome = chromeSize(for: edge)

        let width = CGFloat(columns) * thumbnailWidth
            + CGFloat(columns - 1) * Design.cardGap
            + chrome.width

        let height = CGFloat(rows) * (thumbnailHeight + Design.titleGap + Design.titleHeight)
            + CGFloat(rows - 1) * Design.cardGap
            + chrome.height

        return Metrics(size: CGSize(width: width, height: height),
                       thumbnailWidth: thumbnailWidth, columns: columns)
    }

    // MARK: - Updates

    func update(windows: [WindowInfo], applicationName: String) {
        self.applicationName = applicationName
        self.windows = windows
        hoveredWindow = nil
        keyboardFocusIndex = nil
        // Keep images for windows that survived, drop the rest so a stale thumbnail never
        // shows under a different window's title.
        let live = Set(windows.map(\.id))
        thumbnails = thumbnails.filter { live.contains($0.key) }
    }

    func clear() {
        windows = []
        thumbnails = [:]
        hoveredWindow = nil
        keyboardFocusIndex = nil
        snapScale = 1
    }

    /// The "snap in" popup animation: a brief scale-up as the bubble appears.
    func snapIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            snapScale = 1
            return
        }
        snapScale = 0.96
        withAnimation(Design.appear) { snapScale = 1 }
    }
}
