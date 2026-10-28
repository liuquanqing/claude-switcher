import AppKit

/// The app replaces the main menu with only "open/quit", so the standard responder-chain
/// editing key equivalents (⌘V, ⌘C, ⌘A, ⌘Z …) never reach text fields. Adding a standard
/// Edit menu restores them without any custom handling.
@MainActor
enum ApplicationMenus {
    static func addEditMenu(to mainMenu: NSMenu) {
        guard !mainMenu.items.contains(where: { $0.submenu?.title == "编辑" }) else { return }
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        item.submenu = edit
        mainMenu.addItem(item)
    }
}
