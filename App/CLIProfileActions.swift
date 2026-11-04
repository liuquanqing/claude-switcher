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
            let command = try CLIProfileLaunch.command(profile: profile, home: FileManager.default.homeDirectoryForCurrentUser)
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(command, forType: .string)
        } catch { banner = error.localizedDescription; return false }
    }
}
