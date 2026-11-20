import Foundation
import SwitcherCore

@MainActor extension Store {
    var displayedCLIBackupNotice: String? {
        guard let notice = cliBackupNotice,
              protection.desktopScope == .subscription,
              notice.target.name == current,
              let identity = active?.snapshot?.identity,
              notice.target.identity?.samePrincipal(as: identity) == true,
              ![.different, .needsLogin, .otherAuthentication, .unsupportedStorage].contains(cliStatus)
        else { return nil }
        return notice.message
    }

    private var observedCLIBackupTarget: CLIProfileIdentity? {
        guard protection.desktopScope == .subscription, !defaultCLISyncNeedsReview,
              cliProfile == current, [.unverified, .reported, .matched].contains(cliStatus),
              let identity = active?.snapshot?.identity, cliObservedIdentity?.samePrincipal(as: identity) == true
        else { return nil }
        return CLIProfileIdentity(name: current, identity: identity)
    }

    func refreshCurrentCLIBackup(operation: (() async throws -> Void)? = nil) async {
        guard observedCLIBackupTarget != nil else { return }
        do {
            if let operation { try await operation() }
            else { try await backupCurrentDefaultCLI(manual: true) }
        } catch {
            // The backup entry records the reason. A backup failure must not change the usage refresh result.
        }
    }

    func maintainCurrentCLIBackup(now: Date = Date(), operation: (() async throws -> Void)? = nil) async {
        guard !isDemo || operation != nil else { return }
        guard !updating, busy == nil, !refreshing, !statusRefreshInProgress, !currentCLIRecoveryRunning,
              let target = observedCLIBackupTarget,
              currentCLIBackupAttemptAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        currentCLIBackupAttemptAt = now
        do {
            if let operation { try await operation() }
            else { try await backupCurrentDefaultCLI(manual: false) }
        } catch {
            if observedCLIBackupTarget == target { currentCLIBackupPending = target }
        }
    }

    func backupCurrentDefaultCLI(manual: Bool, io provided: CLICredentialIO? = nil,
                                 gate suppliedGate: (() async -> Bool)? = nil,
                                 verify suppliedVerify: ((String) async throws -> CLIIdentity)? = nil,
                                 context suppliedContext: (() throws -> Bool)? = nil) async throws {
        guard !isDemo || (provided != nil && suppliedContext != nil) else {
            throw SafetyError("演示模式不读取真实登录。")
        }
        guard protection.desktopScope == .subscription, !defaultCLISyncNeedsReview,
              !updating, !currentCLIRecoveryRunning, let identity = active?.snapshot?.identity,
              identity.isComplete else { throw SafetyError("CLI 备份尚未完成，请稍后刷新重试。") }
        let name = current
        if !isDemo {
            guard cliConfiguration().allowsSubscriptionMutation else {
                throw SafetyError("CLI 认证配置未确认，未更新备份。")
            }
        }
        currentCLIRecoveryRunning = true
        defer { currentCLIRecoveryRunning = false }
        let io = provided ?? NativeCLIStorage(allowInteraction: manual, secretWriter: { service, account, data in
            guard let data else { throw SafetyError("当前登录备份不删除凭据。") }
            try KeychainWriteAccess.backup(service: service, account: account, data: data, allowInteraction: manual)
        })
        defer {
            if let native = io as? NativeCLIStorage { lastRefreshDiagnostics?.credentialReads = native.readSummary }
        }
        let target = CLIProfileIdentity(name: name, identity: identity)
        func matchesCurrent() -> Bool {
            protection.desktopScope == .subscription && current == name
                && active?.snapshot?.identity.samePrincipal(as: identity) == true
        }
        let verify: ((String) async throws -> CLIIdentity)? = suppliedVerify
            ?? (isDemo ? nil : { access in try await self.checkedCLIIdentity(access) })
        do {
            _ = try await CLICurrentBackup.save(target: target, io: io,
                contextIsCurrent: {
                    guard matchesCurrent() else { return false }
                    if let suppliedContext { return try suppliedContext() }
                    return try confirmedCurrentProfile() == name
                        && DesktopModeInspector.read(support: support) == .subscription
                        && self.cliConfiguration().allowsSubscriptionMutation
                }, gate: suppliedGate ?? { true }, verify: verify)
            guard matchesCurrent() else { return }
            currentCLIBackupPending = nil
            cliBackupNotice = nil
        } catch {
            if matchesCurrent(), manual {
                currentCLIBackupPending = target
                let message: String
                switch error {
                case is CLIInteractionRequired: message = "CLI 备份需要 macOS 钥匙串授权。"
                case CLICurrentBackup.Deferred.renewalRequired: message = "CLI 备份待更新，等待 Claude Code 续期。"
                case CLICurrentBackup.Deferred.identityUnconfirmed: message = "CLI 登录归属未确认，备份保留原样。"
                case CLICurrentBackup.Deferred.verificationUnavailable: message = "暂时无法在线核验 CLI 登录，备份保留原样。"
                default: message = "本次未能更新 CLI 备份。"
                }
                cliBackupNotice = (target, message)
            }
            throw error
        }
    }
}
