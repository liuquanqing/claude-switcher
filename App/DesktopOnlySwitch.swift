import Foundation
import SwitcherCore

struct DesktopOnlySwitchOffer: Equatable {
    let source: String
    let target: String
    let reason: String
}

@MainActor extension Store {
    func confirmDesktopOnlySwitch() async {
        guard busy == nil, !refreshing, let offer = desktopOnlyOffer else { return }
        desktopOnlyOffer = nil
        await switchDesktopOnly(from: offer.source, to: offer.target, announce: true)
    }

    /// The desktop moves first; the default CLI login then follows the account through
    /// `CLIDefaultMirror`. A CLI preparation problem never blocks the desktop and never
    /// signs the terminal out; the mismatch is reported instead.
    func switchDesktopOnly(from source: String, to target: String, announce: Bool = false) async {
        banner = nil; busy = "检查网络与桌面档案…"
        defer { busy = nil }
        if isDemo {
            let gate = await protection.preflight()
            guard gate.allowed else { banner = gate.message; return }
            guard current == source else { banner = "当前档案已变化，请重新选择。"; return }
            current = target
            cliStatus = .unverified
            cliStatusDetail = nil; cliStatusCheckedAt = nil; cliStandaloneVerified = false
            cliProfile = target; cliEmail = profiles.first { $0.name == target }?.snapshot?.email
            cliStatus = cliEmail == nil ? .needsLogin : .matched
            cliStatusCheckedAt = cliEmail == nil ? nil : Date()
            if announce { banner = "演示：桌面与默认终端登录已一起切换。" }
            return
        }
        let terminalsBefore = runningCLITerminals()
        do {
            let targetConfig = parkDir.appendingPathComponent(target).appendingPathComponent("claude_desktop_config.json")
            try await DesktopOnlyFlow.run(transaction: ProfileTransaction(live: liveDir, parked: parkDir, marker: currentFile),
                from: source, to: target, current: confirmedCurrentProfile, subscriptionMode: {
                    let documents: [Data]
                    do { documents = [try Data(contentsOf: targetConfig)] }
                    catch let e as CocoaError where e.code == .fileReadNoSuchFile { documents = [] }
                    return DesktopModeInspector.read(support: support) == .subscription && DesktopModeInspector.classify(documents) == .subscription
                }, quit: { await quitClaude() }, check: { await self.protection.preflight() }, launch: {
                try await launchProtectedDesktop(files: self.protection.files)
                self.protection.refreshStatus()
            })
            reloadList()
            let follow = await followDefaultCLI(to: target, terminalsBefore: terminalsBefore)
            await refreshCLI(verify: false)
            if let follow { presentCLIRestoration(follow.restoration, target: target, identity: active?.snapshot?.identity) }
            if let message = follow?.notice ?? (announce ? "桌面已切换。" : nil) { banner = message }
        } catch {
            reloadList(); await refreshCLI(verify: false)
            let outcome = (error as? DesktopOnlyFailure)?.directoryChanged
            let phase: String
            switch outcome {
            case true?: phase = "桌面目录已切换，打开或保护未全部完成，请核对 Claude 状态。"
            case false?: phase = "桌面目录未移动。"
            case nil: phase = "桌面移动未完成，请核对还原结果。"
            }
            banner = "\(phase) \(error.localizedDescription) CLI 登录保持原样。"
        }
    }

    struct DefaultCLIFollow {
        let restoration: CLIRestoration
        let notice: String?
    }

    /// Read-only list of user CLI processes; this app's own status/renewal helpers are excluded.
    func runningCLITerminals() -> [Int32] {
        guard !isDemo, let output = try? LocalCommand.run("/bin/ps", ["-axo", "pid=,comm="]), output.0 == 0 else { return [] }
        return CLIDefaultMirror.terminalProcesses(psOutput: output.1, own: BoundedCLICommand.ownProcessIDs())
    }

    private func followDefaultCLI(to target: String, terminalsBefore: [Int32]) async -> DefaultCLIFollow? {
        guard let identity = active?.snapshot?.identity, identity.isComplete else { return nil }
        guard cliConfiguration().allowsSubscriptionMutation else {
            return DefaultCLIFollow(restoration: .needsLogin, notice: "桌面已切换；默认 CLI 使用其他认证配置，登录保持原样。")
        }
        busy = "正在让默认终端登录跟随账号…"
        defer { busy = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let io = NativeCLIStorage(allowInteraction: true)
        let repository = CLIBindingRepository(file: protection.files.directory.appendingPathComponent("cli-bindings.json"), home: home)
        let profiles = self.profiles.map { CLIProfileIdentity(name: $0.name, identity: $0.snapshot?.identity) }
        do {
            let outcome = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: io),
                target: CLIProfileIdentity(name: target, identity: identity), profiles: profiles, home: home, repository: repository,
                remote: { try await self.checkedCLIIdentity($0) },
                terminalsBefore: { terminalsBefore }, terminalsNow: { [weak self] in self?.runningCLITerminals() ?? [] })
            cliConnection.defaultLoginDidChange()
            resetCurrentCLIRecoveryObservation()
            usageRefreshPolicy.credentialsChanged(profile: target); usageCatchUpPending = true
            let notice = followNotice(target: target, restoration: outcome.restoration, previousTerminals: outcome.previousTerminals)
            return DefaultCLIFollow(restoration: outcome.restoration, notice: notice)
        } catch {
            cliConnection.defaultLoginDidChange()
            return DefaultCLIFollow(restoration: .needsLogin, notice: "桌面已切换；默认终端登录未跟随：\(error.localizedDescription)")
        }
    }

    func followNotice(target: String, restoration: CLIRestoration, previousTerminals: Int) -> String? {
        var notes: [String] = []
        if restoration == .needsLogin {
            notes.append(appText("switch.followNeedsLogin", language: appLanguage, arguments: ["target": target]))
        }
        if previousTerminals > 0 {
            notes.append(appText("switch.followOldTerminals", language: appLanguage,
                                 arguments: ["count": String(previousTerminals), "target": target]))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
