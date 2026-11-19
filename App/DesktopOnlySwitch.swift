import Foundation
import Security
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
        do {
            // The cached profile identity can be stale if the target was re-signed-in elsewhere.
            // Confirm the desktop's own identity before any terminal credential is written.
            let confirmed = try await profileDescriptor(target, allowInteraction: true)
            guard let confirmedIdentity = confirmed.identity, confirmedIdentity.isComplete,
                  confirmedIdentity.samePrincipal(as: identity), try confirmedCurrentProfile() == target,
                  DesktopModeInspector.read(support: support) == .subscription else {
                throw SafetyError("目标桌面的实际账号与档案记录不一致，终端登录保持原样。")
            }
            let profiles = self.profiles.map { CLIProfileIdentity(name: $0.name, identity: $0.snapshot?.identity) }
            let outcome = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: io),
                target: CLIProfileIdentity(name: target, identity: identity), profiles: profiles, home: home, repository: repository,
                storeFor: { Self.isolatedStore($0, allowInteraction: true) },
                journalURL: protection.files.directory.appendingPathComponent("cli-transcript-links.json"),
                remote: { try await self.checkedCLIIdentity($0) },
                contextIsCurrent: { try confirmedCurrentProfile() == target && self.current == target
                    && self.active?.snapshot?.identity.samePrincipal(as: identity) == true
                    && DesktopModeInspector.read(support: support) == .subscription },
                terminalsBefore: { terminalsBefore }, terminalsNow: { [weak self] in self?.runningCLITerminals() ?? [] })
            cliConnection.defaultLoginDidChange()
            resetCurrentCLIRecoveryObservation()
            usageRefreshPolicy.credentialsChanged(profile: target); usageCatchUpPending = true
            cliFollowPending = nil
            let notice = followNotice(target: target, restoration: outcome.restoration, previousTerminals: outcome.previousTerminals)
            return DefaultCLIFollow(restoration: outcome.restoration, notice: notice)
        } catch {
            cliConnection.defaultLoginDidChange()
            cliFollowPending = target
            return DefaultCLIFollow(restoration: .needsLogin, notice: "桌面已切换；默认终端登录未跟随：\(error.localizedDescription)")
        }
    }

    /// Retry the terminal follow for the current desktop after a failed attempt.
    func retryDefaultCLIFollow() async {
        guard !isDemo, busy == nil, !refreshing, let target = cliFollowPending, target == current else { return }
        let before = runningCLITerminals()
        let result = await followDefaultCLI(to: target, terminalsBefore: before)
        await refreshCLI(verify: false)
        if let result { presentCLIRestoration(result.restoration, target: target, identity: active?.snapshot?.identity) }
        banner = result?.notice ?? (cliFollowPending == nil ? "默认终端登录已跟随当前账号。" : banner)
    }

    /// The account's own directory uses the official CLI's directory-scoped Keychain item with a
    /// private-file fallback, exactly like the recovery adapter. A denied read is never "empty".
    static func isolatedStore(_ directory: URL, allowInteraction: Bool) -> CLIDefaultMirror.DirectoryStore {
        let service = OfficialCLIRecovery.service(for: directory)
        let account = NSUserName()
        return CLIDefaultMirror.DirectoryStore(directory: directory,
            readScoped: { try KeychainReadAccess.read(service: service, account: account, allowInteraction: allowInteraction) },
            writeScoped: { data in
                if let data { try writeKeychain(service: service, account: account, json: CLIJSON.object(data)) }
                else {
                    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service, kSecAttrAccount as String: account]
                    let status = SecItemDelete(query as CFDictionary)
                    guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw SafetyError("独立目录登录还原失败（状态 \(status)）。") }
                }
            })
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
