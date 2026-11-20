import AppKit
import SwitcherCore

@MainActor extension Store {
    /// The header's terminal icon: open the bound terminal, or show the directory choice for an
    /// unbound account. All gating stays in the connection controller.
    func openTerminalFromHeader() async {
        guard protection.desktopScope == .subscription, !updating, busy == nil else { return }
        guard await prepareTerminalIdentity() else { return }
        await cliConnection.open(showLoginChoices: cliConnection.currentBinding == nil && cliConnection.preferredChoice != .defaultLogin)
    }

    @discardableResult
    func copyScopedCLICommand() -> Bool {
        guard busy == nil, !refreshing, !statusRefreshInProgress,
              protection.desktopScope == .subscription else { return false }
        if isDemo { return true }
        do {
            let profile = try confirmedCurrentProfile()
            guard profile == current else { return false }
            let home = FileManager.default.homeDirectoryForCurrentUser
            guard let binding = cliConnection.bindingForCachedUsage(),
                  active?.snapshot?.identity.samePrincipal(as: binding.identity) == true else {
                throw SafetyError("请先在切换器中打开终端，确认账号目录后再复制命令。")
            }
            let proxy = try CLITerminalLaunch.readSystemProxy()
            let command = try CLITerminalLaunch.command(binding: binding,
                executable: CLITerminalLaunch.executable(home: home), home: home, proxy: proxy)
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(command, forType: .string)
        } catch { banner = error.localizedDescription; return false }
    }
}
