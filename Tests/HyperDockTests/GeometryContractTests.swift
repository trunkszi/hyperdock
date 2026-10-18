import CoreGraphics
import Testing
@testable import HyperDock

private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

@Test func hoverStripReachesIntoTheScreenForEveryDockEdge() {
    // A vertical Dock: thin and tall. The left case once took its *height* as the depth
    // and put the entire strip outside the screen.
    let left = CGRect(x: 0, y: 200, width: 64, height: 700)
    let leftStrip = DockWatcher.hoverStrip(forDock: left, edge: .left, screenFrame: screen)
    #expect(leftStrip.contains(CGPoint(x: 32, y: 550)))      // on an icon
    #expect(leftStrip.contains(CGPoint(x: 1, y: 550)))       // at the screen edge
    #expect(leftStrip.minX == -64)                           // one Dock width outside
    #expect(leftStrip.maxX == 128)                           // two inside

    // Auto-hidden: the tiles sit one Dock width off screen, and the strip must still
    // cover the edge the pointer pushes against.
    let hiddenLeft = CGRect(x: -64, y: 200, width: 64, height: 700)
    #expect(DockWatcher.hoverStrip(forDock: hiddenLeft, edge: .left, screenFrame: screen)
        .contains(CGPoint(x: 0.5, y: 550)))

    let right = CGRect(x: screen.maxX - 64, y: 200, width: 64, height: 700)
    let rightStrip = DockWatcher.hoverStrip(forDock: right, edge: .right, screenFrame: screen)
    #expect(rightStrip.contains(CGPoint(x: screen.maxX - 32, y: 550)))
    #expect(rightStrip.maxX == screen.maxX + 64)

    let bottom = CGRect(x: 400, y: 0, width: 900, height: 64)
    let bottomStrip = DockWatcher.hoverStrip(forDock: bottom, edge: .bottom, screenFrame: screen)
    #expect(bottomStrip.contains(CGPoint(x: 850, y: 32)))
    #expect(bottomStrip.minY == -64)
}

@Test func onlyThePointerNearAnotherScreensDockEdgeCountsAsReachingForTheDock() {
    #expect(DockWatcher.isNearDockEdge(CGPoint(x: 800, y: 20), of: screen,
                                       edge: .bottom, thickness: 64))
    #expect(!DockWatcher.isNearDockEdge(CGPoint(x: 800, y: 600), of: screen,
                                        edge: .bottom, thickness: 64))
    #expect(DockWatcher.isNearDockEdge(CGPoint(x: 10, y: 600), of: screen,
                                       edge: .left, thickness: 64))
    #expect(!DockWatcher.isNearDockEdge(CGPoint(x: 10, y: 600), of: screen,
                                        edge: .right, thickness: 64))
}

@Test func resizingFromTheLeftOrTopHoldsTheOppositeEdges() {
    let start = CGRect(x: 100, y: 100, width: 800, height: 600)
    let minimum = CGSize(width: 120, height: 80)

    // Grabbed near the top-left: the right and bottom edges are the ones held.
    let (frame, anchor) = WindowManager.resizedFrame(
        from: start, grabbedAt: CGPoint(x: 150, y: 150), dx: 50, dy: 40, minimum: minimum)
    #expect(frame == CGRect(x: 150, y: 140, width: 750, height: 560))
    #expect(anchor == WindowManager.ResizeAnchor(maxX: 900, maxY: 700))

    // The application refused to go below 780 × 600: putting the held edges back must
    // keep them at 900 and 700 instead of letting the window slide right and down.
    let applied = CGRect(x: 150, y: 140, width: 780, height: 600)
    let corrected = WindowManager.reanchored(applied, to: anchor!)
    #expect(corrected.maxX == 900)
    #expect(corrected.maxY == 700)
    #expect(corrected.size == applied.size)

    // Grabbed near the bottom-right: nothing to hold, the origin never moves.
    let (grown, none) = WindowManager.resizedFrame(
        from: start, grabbedAt: CGPoint(x: 850, y: 650), dx: 30, dy: 20, minimum: minimum)
    #expect(grown == CGRect(x: 100, y: 100, width: 830, height: 620))
    #expect(none == nil)
}

@Test func gridGapNeverProducesCellsBelowTheMinimum() {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let frames = WindowGrid.frames(count: 6, in: area, fixedColumns: 3, fixedRows: 2, gap: 5000)
    #expect(frames.count == 6)
    for frame in frames {
        #expect(frame.width >= 40)
        #expect(frame.height >= 40)
        #expect(area.contains(frame.insetBy(dx: 0.5, dy: 0.5)))
    }

    // An ordinary gap is left alone.
    let spaced = WindowGrid.frames(count: 2, in: area, fixedColumns: 2, fixedRows: 1, gap: 20)
    #expect(spaced[1].minX - spaced[0].maxX == 20)
}

@Test func bubbleThumbnailsShrinkToFitTheScreen() {
    let chrome = CGSize(width: 28, height: 28)
    // Plenty of room: the preferred width stands.
    #expect(BubbleModel.fittedThumbnailWidth(preferred: 300, columns: 2, rows: 1,
                                             aspectRatio: 1.6, chrome: chrome,
                                             limit: CGSize(width: 3000, height: 2000)) == 300)

    // Five columns of 360 pt on a 1200 pt wide screen: narrowed until the row fits.
    let narrow = BubbleModel.fittedThumbnailWidth(preferred: 360, columns: 5, rows: 1,
                                                  aspectRatio: 1.6, chrome: chrome,
                                                  limit: CGSize(width: 1200, height: 1000))
    #expect(5 * narrow + 4 * Design.cardGap + chrome.width <= 1200)

    // Four rows on a short screen: narrowed until the column fits.
    let short = BubbleModel.fittedThumbnailWidth(preferred: 360, columns: 5, rows: 4,
                                                 aspectRatio: 1.6, chrome: chrome,
                                                 limit: CGSize(width: 3000, height: 800))
    let rowHeight = (short / 1.6).rounded() + Design.titleGap + Design.titleHeight
    #expect(4 * rowHeight + 3 * Design.cardGap + chrome.height <= 800)
}
