import AppKit
import XCTest
@testable import GujType

final class HotkeyTests: XCTestCase {
    func testRepeatedSessionsAndDuplicateEvents() {
        var presses = 0, releases = 0
        let monitor = HotkeyMonitor(shortcut: .defaultShortcut, onPress: { presses += 1 }, onRelease: { releases += 1 })
        for _ in 0..<10 {
            monitor.handleDown(event(.keyDown))
            monitor.handleDown(event(.keyDown))
            monitor.handleDown(event(.keyDown, repeatKey: true))
            monitor.handleUp(event(.keyUp, modifiers: []))
            monitor.handleUp(event(.keyUp, modifiers: []))
        }
        XCTAssertEqual(presses, 10)
        XCTAssertEqual(releases, 10)
    }

    func testModifierReleaseRecoversMissingKeyUp() {
        var presses = 0, releases = 0
        let monitor = HotkeyMonitor(shortcut: .defaultShortcut, onPress: { presses += 1 }, onRelease: { releases += 1 })
        monitor.handleDown(event(.keyDown))
        monitor.handleFlags(event(.flagsChanged, modifiers: []))
        monitor.handleDown(event(.keyDown, repeatKey: true))
        monitor.handleDown(event(.keyDown))
        monitor.handleUp(event(.keyUp))
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(releases, 2)
    }

    private func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = .control, repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil,
                        characters: "0", charactersIgnoringModifiers: "0", isARepeat: repeatKey, keyCode: 29)!
    }
}
