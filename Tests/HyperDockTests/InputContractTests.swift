import CoreGraphics
import Testing
@testable import HyperDock

@Test func rightMouseDownMapsToConfiguredRightButton() {
    #expect(DockMouseButton(eventType: .rightMouseDown, buttonNumber: 1) == .right)
    let rightMouseBit: CGEventMask = 1 << CGEventType.rightMouseDown.rawValue
    #expect(WindowManager.eventMask & rightMouseBit != 0)
}

@Test func onlySupportedMouseDownEventsBecomeDockButtons() {
    #expect(DockMouseButton(eventType: .leftMouseDown, buttonNumber: 0) == .left)
    #expect(DockMouseButton(eventType: .otherMouseDown, buttonNumber: 2) == .middle)
    #expect(DockMouseButton(eventType: .otherMouseDown, buttonNumber: 3) == nil)
    #expect(DockMouseButton(eventType: .leftMouseUp, buttonNumber: 0) == nil)
}

@Test func onlyAnUnmodifiedEscapeDismissesTheBubble() {
    #expect(WindowManager.bubbleKey(keyCode: 53, flags: []) == .dismiss)
    // ⌘⌥Esc is Force Quit and must reach the system.
    #expect(WindowManager.bubbleKey(keyCode: 53,
                                    flags: [.maskCommand, .maskAlternate]) == nil)
    #expect(WindowManager.bubbleKey(keyCode: 53, flags: .maskShift) == nil)
}

@Test func edgeSnapNeedsAMoveDragThatCanActuallyStart() {
    let move: ModifierCombo = [.control, .option]
    let resize: ModifierCombo = [.control, .option, .shift]
    #expect(WindowManager.isMoveDragReachable(moveEnabled: true, moveModifiers: move,
                                              resizeEnabled: true, resizeModifiers: resize))
    #expect(!WindowManager.isMoveDragReachable(moveEnabled: false, moveModifiers: move,
                                               resizeEnabled: true, resizeModifiers: resize))
    #expect(!WindowManager.isMoveDragReachable(moveEnabled: true, moveModifiers: [],
                                               resizeEnabled: true, resizeModifiers: resize))
    // Resize is matched first, so an identical combination shadows move entirely.
    #expect(!WindowManager.isMoveDragReachable(moveEnabled: true, moveModifiers: move,
                                               resizeEnabled: true, resizeModifiers: move))
    #expect(WindowManager.isMoveDragReachable(moveEnabled: true, moveModifiers: move,
                                              resizeEnabled: false, resizeModifiers: move))
}

@Test func activationDelayIsBoundedInsteadOfOverflowing() {
    #expect(DockWatcher.activationDelay(milliseconds: 70) == .milliseconds(70))
    #expect(DockWatcher.activationDelay(milliseconds: -5) == .zero)
    #expect(DockWatcher.activationDelay(milliseconds: .max) == .milliseconds(5000))
}

@Test func everySelectableModifierRoundTripsThroughEventFlags() {
    let expected: [(ModifierCombo, CGEventFlags)] = [
        (.control, .maskControl),
        (.option, .maskAlternate),
        (.command, .maskCommand),
        (.shift, .maskShift),
    ]

    #expect(ModifierCombo.userSelectable == expected.map(\.0))
    for (modifier, flags) in expected {
        #expect(ModifierCombo(eventFlags: flags) == modifier)
    }
}
