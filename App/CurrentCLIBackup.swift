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
        // The default login is a view of the current account. If the account has its own
        // directory, that directory is the original: refresh it from the default first so
        // its renewal is never lost when the next switch copies it back.
        let name = current
        currentCLIBackupAttemptAt = now
        do {
            if let operation { try await operation() }
            else {
                // The passive path verifies under the existing CLI network gate so the backup keeps
                // a proof bound to this credential; a gate/verification failure leaves the old backup.
                try await backupCurrentDefaultCLI(manual: false, gate: { await self.protection.preflight(target: .cli).allowed },
                    verify: { token in try await self.checkedCLIIdentity(token) })
            }
            // Only a login whose identity was verified online for this exact credential digest is
            // copied back into the account's own directory; the backup holds that proof.
            if !isDemo, operation == nil,
               let own = try? CLIDefaultMirror.isolatedDirectory(identity: identity, profile: name,
                   home: FileManager.default.homeDirectoryForCurrentUser,
                   repository: CLIBindingRepository(file: protection.files.directory.appendingPathComponent("cli-bindings.json"),
                                                    home: FileManager.default.homeDirectoryForCurrentUser)),
               let raw = try NativeCLIStorage(allowInteraction: false, secretWriter: { _, _, _ in throw SafetyError("read-only") }).readBackup(name),
               let verification = try CLIBackup(data: raw).verification {
                await mirrorDefaultLoginIntoOwnDirectory(own, identity: identity, verified: verification, manual: false, now: now)
            }
        } catch {
            guard current == name, active?.snapshot?.identity.samePrincipal(as: identity) == true else { return }
            currentCLIBackupPending = CLIProfileIdentity(name: name, identity: identity)
            if banner == nil { banner = "已登录，但备份尚未更新。请点击刷新重试。" }
        }
    }

    /// Copy the owned OAuth field and `oauthAccount` from the default store into the account's own
    /// directory when the default holds the same account and a newer credential. Only these two
    /// fields are written; a differing account in either place stops the copy.
    func mirrorDefaultLoginIntoOwnDirectory(_ directory: URL, identity: CLIIdentity, verified: CLIVerification?, manual: Bool, now: Date = Date(),
                                            io provided: CLICredentialIO? = nil) async {
        let io = provided ?? NativeCLIStorage(allowInteraction: manual)
        do {
            try CLIDefaultMirror.refreshOwnDirectory(from: io, store: Store.isolatedStore(directory, allowInteraction: manual),
                                                     expected: identity, verified: verified, now: { now })
        } catch {
            if manual { banner = "独立目录尚未同步最新登录：\(error.localizedDescription)" }
            else if banner == nil { banner = "独立目录尚未同步最新登录：\(error.localizedDescription)" }
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
