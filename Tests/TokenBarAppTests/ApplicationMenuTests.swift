import AppKit
import XCTest
@testable import token_bar

final class ApplicationMenuTests: XCTestCase {
    private let shortcuts: [(action: String, key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("undo:", "z", []),
        ("redo:", "Z", .shift),
        ("cut:", "x", []),
        ("copy:", "c", []),
        ("paste:", "v", []),
        ("selectAll:", "a", []),
    ]

    @MainActor
    private func editMenu() throws -> NSMenu {
        NSApplication.shared.setActivationPolicy(.accessory)
        return try XCTUnwrap(makeApplicationMenu().items.first { $0.title == "Edit" }?.submenu)
    }

    @MainActor
    private func keyEvent(_ key: String, modifiers: NSEvent.ModifierFlags,
                          windowNumber: Int = 0) throws -> NSEvent {
        let keyCodes: [String: UInt16] = ["a": 0, "b": 11, "c": 8, "e": 14,
                                        "v": 9, "x": 7, "z": 6]
        let characters: String
        if modifiers.contains(.control), let scalar = key.lowercased().unicodeScalars.first {
            characters = String(UnicodeScalar(scalar.value - 96)!)
        } else {
            characters = key
        }
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: keyCodes[key.lowercased()] ?? 0
        ))
    }

    func testCommandShortcutsUseTheResponderChain() async throws {
        try await MainActor.run {
            let menu = try editMenu()
            XCTAssertTrue(menu.autoenablesItems)
            let items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
            XCTAssertEqual(items.count, shortcuts.count)
            for (item, shortcut) in zip(items, shortcuts) {
                XCTAssertEqual(item.action, NSSelectorFromString(shortcut.action))
                XCTAssertEqual(item.keyEquivalent, shortcut.key)
                XCTAssertEqual(item.keyEquivalentModifierMask, shortcut.modifiers.union(.command))
                XCTAssertNil(item.target)
            }
        }
    }

    func testControlAliasesWorkWhenHidden() async throws {
        try await MainActor.run {
            let items = try editMenu().items.filter(\.isHidden)
            XCTAssertEqual(items.count, shortcuts.count)
            for (item, shortcut) in zip(items, shortcuts) {
                XCTAssertTrue(item.allowsKeyEquivalentWhenHidden)
                XCTAssertEqual(item.action, NSSelectorFromString(shortcut.action))
                XCTAssertEqual(item.keyEquivalent, shortcut.key)
                XCTAssertEqual(item.keyEquivalentModifierMask, shortcut.modifiers.union(.control))
                XCTAssertNil(item.target)
            }
        }
    }

    func testCommandAndControlKeysDispatchEditingActions() async throws {
        try await MainActor.run {
            let menu = try editMenu()
            let responder = EditingResponder()
            for item in menu.items where !item.isSeparatorItem { item.target = responder }

            for modifier in [NSEvent.ModifierFlags.command, .control] {
                for shortcut in shortcuts {
                    responder.actions.removeAll()
                    let event = try keyEvent(shortcut.key, modifiers: modifier.union(shortcut.modifiers))
                    XCTAssertTrue(menu.performKeyEquivalent(with: event), shortcut.action)
                    XCTAssertEqual(responder.actions, [shortcut.action])
                }
            }
        }
    }

    func testSelectAllReachesTheModalTextField() async throws {
        try await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let previousMenu = app.mainMenu
            app.mainMenu = makeApplicationMenu()
            let alert = NSAlert()
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.stringValue = "example-host"
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            // Exercise real modal responder routing without flashing a test dialog.
            alert.window.alphaValue = 0
            alert.layout()
            let session = app.beginModalSession(for: alert.window)
            defer {
                app.endModalSession(session)
                alert.window.orderOut(nil)
                app.mainMenu = previousMenu
            }
            let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
            for modifier in [NSEvent.ModifierFlags.command, .control] {
                editor.setSelectedRange(NSRange(location: 5, length: 0))
                app.sendEvent(try keyEvent("a", modifiers: modifier,
                                          windowNumber: alert.window.windowNumber))
                XCTAssertEqual(editor.selectedRange(),
                               NSRange(location: 0, length: input.stringValue.utf16.count))
            }
        }
    }

    func testTypingAndUnrelatedShortcutsAreNotConsumed() async throws {
        try await MainActor.run {
            let menu = try editMenu()
            let responder = EditingResponder()
            for item in menu.items where !item.isSeparatorItem { item.target = responder }

            for key in ["a", "c", "v", "x", "z"] {
                XCTAssertFalse(menu.performKeyEquivalent(with: try keyEvent(key, modifiers: [])))
            }
            for (key, modifiers) in [("a", NSEvent.ModifierFlags.command.union(.option)),
                                     ("c", .control.union(.option)),
                                     ("b", .control), ("e", .control)] {
                XCTAssertFalse(menu.performKeyEquivalent(with: try keyEvent(key, modifiers: modifiers)))
            }
            XCTAssertTrue(responder.actions.isEmpty)
        }
    }

    func testUnavailableEditingActionsAreNotInvoked() async throws {
        try await MainActor.run {
            let menu = try editMenu()
            let responder = EditingResponder()
            responder.canEdit = false
            for item in menu.items where !item.isSeparatorItem { item.target = responder }

            for modifier in [NSEvent.ModifierFlags.command, .control] {
                for shortcut in shortcuts {
                    _ = menu.performKeyEquivalent(with: try keyEvent(
                        shortcut.key, modifiers: modifier.union(shortcut.modifiers)
                    ))
                }
            }
            XCTAssertTrue(responder.actions.isEmpty)
        }
    }
}

// Record native menu dispatch without reading or modifying the user's clipboard.
@MainActor
private final class EditingResponder: NSObject, NSMenuItemValidation {
    var actions: [String] = []
    var canEdit = true

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canEdit }
    @objc func undo(_ sender: Any?) { actions.append("undo:") }
    @objc func redo(_ sender: Any?) { actions.append("redo:") }
    @objc func cut(_ sender: Any?) { actions.append("cut:") }
    @objc func copy(_ sender: Any?) { actions.append("copy:") }
    @objc func paste(_ sender: Any?) { actions.append("paste:") }
    @objc func selectAll(_ sender: Any?) { actions.append("selectAll:") }
}
