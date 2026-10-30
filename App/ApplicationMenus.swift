import AppKit

/// The app replaces the main menu with only "open/quit", so the standard responder-chain
/// editing key equivalents (⌘V, ⌘C, ⌘A, ⌘Z …) never reach text fields. Adding a standard
/// Edit menu restores them without any custom handling.
@MainActor
enum ApplicationMenus {
    static func addEditMenu(to mainMenu: NSMenu, language: String) {
        let edit = NSMenu(title: appText("menu.edit", language: language))
        edit.addItem(withTitle: appText("menu.undo", language: language), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: appText("menu.redo", language: language), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: appText("menu.cut", language: language), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: appText("menu.copy", language: language), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: appText("menu.paste", language: language), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: appText("menu.selectAll", language: language), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: appText("menu.edit", language: language), action: nil, keyEquivalent: "")
        item.submenu = edit
        mainMenu.addItem(item)
    }
}
