import AppKit
import SwitcherCore

@MainActor extension Store {
    @discardableResult
    func copyScopedCLICommand() -> Bool {
        guard busy == nil, !refreshing, !statusRefreshInProgress,
              protection.desktopScope == .subscription else { return false }
        if isDemo { return true }
        do {
            let profile = try confirmedCurrentProfile()
            guard profile == current else { return false }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let command: String
            if let binding = cliConnection.currentBinding,
               active?.snapshot?.identity.samePrincipal(as: binding.identity) == true {
                command = try CLITerminalLaunch.command(binding: binding, executable: CLITerminalLaunch.executable(home: home), home: home)
            } else { command = try CLIProfileLaunch.command(profile: profile, home: home) }
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(command, forType: .string)
        } catch { banner = error.localizedDescription; return false }
    }
}
