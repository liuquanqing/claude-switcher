import Foundation
import SwitcherCore

@MainActor extension Store {
    func maintainCurrentCLIBackup(now: Date = Date(), operation: (() async throws -> Void)? = nil) async {
        guard !isDemo || operation != nil else { return }
        guard !updating, busy == nil, !refreshing, !statusRefreshInProgress, !currentCLIRecoveryRunning,
              cliProfile == current, [.unverified, .reported, .matched].contains(cliStatus),
              let identity = active?.snapshot?.identity,
              cliObservedIdentity?.samePrincipal(as: identity) == true,
              currentCLIBackupAttemptAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        let name = current
        currentCLIBackupAttemptAt = now
        do {
            if let operation { try await operation() }
            else { try await backupCurrentDefaultCLI(manual: false) }
        } catch {
            guard current == name, active?.snapshot?.identity.samePrincipal(as: identity) == true else { return }
            currentCLIBackupPending = CLIProfileIdentity(name: name, identity: identity)
            if banner == nil { banner = "已登录，但备份尚未更新。请点击刷新重试。" }
        }
    }

    func backupCurrentDefaultCLI(manual: Bool, io provided: CLICredentialIO? = nil,
                                 gate suppliedGate: (() async -> Bool)? = nil,
                                 verify suppliedVerify: ((String) async throws -> CLIIdentity)? = nil,
                                 context suppliedContext: (() throws -> Bool)? = nil) async throws {
        guard !isDemo || (provided != nil && suppliedContext != nil) else {
            throw SafetyError("演示模式不读取真实登录。")
        }
        guard !updating, !currentCLIRecoveryRunning, let identity = active?.snapshot?.identity,
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
        _ = try await CLICurrentBackup.save(target: .init(name: name, identity: identity), io: io,
            contextIsCurrent: suppliedContext ?? {
                try confirmedCurrentProfile() == name && self.current == name
                    && self.active?.snapshot?.identity.samePrincipal(as: identity) == true
                    && self.cliConfiguration().allowsSubscriptionMutation
            }, gate: suppliedGate ?? { true }, verify: suppliedVerify)
        currentCLIBackupPending = nil
        if banner == "已登录，但备份尚未更新。请点击刷新重试。" { banner = nil }
    }
}
