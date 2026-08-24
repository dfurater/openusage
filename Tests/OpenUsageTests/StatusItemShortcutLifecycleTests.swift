import KeyboardShortcuts
import XCTest
@testable import OpenUsage

@MainActor
final class StatusItemShortcutLifecycleTests: XCTestCase {
    func testRemovingControllerHandlerPreservesShortcutAndAllowsReplacement() {
        let name = KeyboardShortcuts.Name("OpenUsageTests.StatusItemShortcut.\(UUID().uuidString)")
        let shortcut = KeyboardShortcuts.Shortcut(
            .f19,
            modifiers: [.command, .control, .option, .shift]
        )
        defer {
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.reset(name)
        }

        KeyboardShortcuts.setShortcut(shortcut, for: name)
        KeyboardShortcuts.onKeyUp(for: name) {}
        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: name))

        // StatusItemController.shutdown performs this exact operation before creating its
        // replacement. The user's chosen key combination must survive the listener teardown.
        KeyboardShortcuts.removeHandler(for: name)
        XCTAssertFalse(KeyboardShortcuts.isEnabled(for: name))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), shortcut)

        KeyboardShortcuts.onKeyUp(for: name) {}
        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: name))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), shortcut)
    }
}
