import AppKit

// Accessory apps still need an Edit menu to route keyboard shortcuts to the
// active field editor, including the accessory text fields in modal alerts.
@MainActor
func makeApplicationMenu() -> NSMenu {
    let menu = NSMenu()

    func submenu(_ title: String) -> NSMenu {
        let child = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = child
        menu.addItem(item)
        return child
    }

    let applicationMenu = submenu("Token Bar")
    applicationMenu.addItem(withTitle: "Quit Token Bar",
                            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let editMenu = submenu("Edit")
    func editingCommand(_ title: String, _ action: Selector, _ key: String,
                        modifiers: NSEvent.ModifierFlags = []) {
        for modifier in [NSEvent.ModifierFlags.command, .control] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifier.union(modifiers)
            // Leave the target nil so AppKit uses the current responder and
            // automatically disables actions that aren't available.
            if modifier == .control {
                // Offer Ctrl aliases without duplicating visible menu commands.
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
            }
            editMenu.addItem(item)
        }
    }

    editingCommand("Undo", Selector(("undo:")), "z")
    editingCommand("Redo", Selector(("redo:")), "Z", modifiers: .shift)
    editMenu.addItem(.separator())
    editingCommand("Cut", #selector(NSText.cut(_:)), "x")
    editingCommand("Copy", #selector(NSText.copy(_:)), "c")
    editingCommand("Paste", #selector(NSText.paste(_:)), "v")
    editingCommand("Select All", #selector(NSText.selectAll(_:)), "a")
    return menu
}
