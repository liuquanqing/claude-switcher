import Foundation
import SwitcherCore

@MainActor extension Store {
    func resetCurrentCLIRecoveryObservation() {
        clearCurrentCLIRecoveryNotice()
        currentCLIRecoveryOutcome=nil;currentCLIBackupPending=nil;currentCLIObservedLogin=nil
        currentCLIInspectionAt=nil;currentCLIRenewalPolicy=CLIRenewalPolicy()
    }
    func setBackgroundCLIRenewalPermission(_ allowed: Bool) {
        allowBackgroundCLIRenewal = allowed
        currentCLIRenewalPolicy = CLIRenewalPolicy(); currentCLIInspectionAt = nil
        if !isDemo { UserDefaults.standard.set(allowed, forKey: "allowBackgroundCLIRenewal") }
    }
    var cliRecoveryNeedsAttention: Bool {
        switch currentCLIRecoveryOutcome {
        case .needsLogin, .authorizationRequired, .backupPending, .verificationPending, .retryLater, .unsupported: return true
        default: return false
        }
    }

    /// Injection is mandatory for demos. Ordinary status reads remain read-only;
    /// the native CLI is the only writer to the default login during recovery.
    @discardableResult
    func recoverCurrentCLI(manual: Bool = false, requestNativeCheck: Bool = false,
        io provided: CLICredentialIO? = nil,
        context suppliedContext: (() throws -> Bool)? = nil,
        gate suppliedGate: (() async -> Bool)? = nil,
        native suppliedNative: (() async throws -> CLINativeRenewalOutcome)? = nil,
        nativeIsSilent suppliedSilentCapability: Bool? = nil,
        verify suppliedVerify: ((String) async throws -> CLIIdentity)? = nil,
        now: Date = Date()) async -> CLICurrentRecoveryOutcome {
        guard !isDemo || (provided != nil && suppliedContext != nil && suppliedGate != nil && suppliedNative != nil && suppliedVerify != nil) else { return .unsupported }
        guard busy == nil, !refreshing, !currentCLIRecoveryRunning else { return .notNeeded }
        currentCLIRecoveryDidRunNative = false
        if !isDemo && !cliConfiguration().allowsSubscriptionMutation {
            clearCurrentCLIRecoveryNotice();currentCLIRecoveryOutcome=nil;currentCLIBackupPending=nil;currentCLIObservedLogin=nil
            return .unsupported
        }
        if !manual, let last = currentCLIInspectionAt, now.timeIntervalSince(last) < 60 {
            return currentCLIRecoveryOutcome ?? .notNeeded
        }
        currentCLIInspectionAt = now
        let name = current, scope = protection.desktopScope
        guard scope != .unknown, let identity = active?.snapshot?.identity, identity.isComplete else { return .notNeeded }
        let context = suppliedContext ?? {
            try confirmedCurrentProfile() == name && self.current == name
                && DesktopModeInspector.read(support: support) == scope
                && self.cliConfiguration().allowsSubscriptionMutation
        }
        let gate = suppliedGate ?? { await self.protection.preflight(target: .cli).allowed }
        // Hold the UI's own operation slot before an interactive Keychain read.
        // In particular, a user approving recovery does not bypass its region gate.
        if manual {
            currentCLIRecoveryRunning = true;busy = "检查恢复网络…"
            guard await gate() else {
                busy=nil;currentCLIRecoveryRunning=false
                let message = "网络检查未通过，暂不请求授权或恢复登录。"
                clearCurrentCLIRecoveryNotice();currentCLIRecoveryMessage=message
                currentCLIRecoveryOutcome = .retryLater
                if banner == nil { banner=message }
                return .retryLater
            }
            guard (try? context()) == true else {
                busy=nil;currentCLIRecoveryRunning=false
                resetCurrentCLIRecoveryObservation();invalidateCLIStatus()
                return .contextChanged
            }
        }
        defer { if manual { busy=nil } }
        let io = provided ?? NativeCLIStorage(allowInteraction: manual, secretWriter: { service, account, data in
            guard let data else { throw SafetyError("当前登录恢复不删除原生登录。") }
            try KeychainWriteAccess.backup(service: service, account: account, data: data, allowInteraction: manual)
        })
        defer {
            if manual, let native = io as? NativeCLIStorage { lastRefreshDiagnostics?.credentialReads = native.readSummary }
        }
        func owned() throws -> CLIOwnedLogin {
            try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
        }
        currentCLIRecoveryRunning = true
        defer { currentCLIRecoveryRunning = false }
        var observedIdentity: CLIIdentity?
        do {
            guard try context(), let metadata = try CLIIdentity.metadata(CLIJSON.field(io.readIdentityDocument(), key: "oauthAccount")),
                  metadata.samePrincipal(as: identity) else { return .contextChanged }
            observedIdentity = metadata
            let before = try owned()
            guard try context(), try before.identity?.samePrincipal(as: identity) == true else {
                currentCLIRecoveryOutcome = nil; currentCLIBackupPending = nil
                return .contextChanged
            }
            let changedNativeLogin = currentCLIObservedLogin.map {
                $0.name == name && $0.identity.samePrincipal(as: identity) && $0.version != before.digest
            } ?? false
            currentCLIObservedLogin = (name, identity, before.digest)
            if changedNativeLogin {
                usageRefreshPolicy.credentialsChanged(profile: name)
                usageCatchUpPending = true
                currentCLIBackupPending = CLIProfileIdentity(name: name, identity: identity)
            }
            let pending = changedNativeLogin || (currentCLIBackupPending.map { $0.name == name && $0.identity?.samePrincipal(as: identity) == true } ?? false)
            let due = try CLICurrentRecovery.isDue(before, now: now)
            var forceNativeCheck = requestNativeCheck
            if !pending && !forceNativeCheck && !due {
                if cliRecoveryNeedsAttention && currentCLIRecoveryOutcome != .retryLater && currentCLIRecoveryOutcome != .authorizationRequired && !changedNativeLogin {
                    return currentCLIRecoveryOutcome ?? .notNeeded
                }
                // A read-only cold-start verification is independent of renewal.
                // A temporary profile/route failure must be allowed to recover
                // next tick instead of freezing a healthy login in retryLater.
                if manual || cliStatus == .unverified && !cliStandaloneVerified || cliStatus == .reported || currentCLIRecoveryOutcome == .retryLater || currentCLIRecoveryOutcome == .authorizationRequired {
                    guard let access = before.usableAccessToken(now: now), await gate(), try context() else {
                        return currentCLIRecoveryOutcome ?? .notNeeded
                    }
                    do {
                        let actual = try await (suppliedVerify ?? { CLIIdentity.profile(try await getJSON("profile", $0)) })(access)
                        guard actual.isComplete, actual.samePrincipal(as: identity), try context(), try owned() == before else { return .contextChanged }
                        cliObservedIdentity = actual;cliProfile = name;cliEmail = actual.email
                        cliStatus = scope == .subscription ? .matched : .unverified
                        cliStandaloneVerified = scope != .subscription;cliStatusCheckedAt = now;cliStatusDetail = nil
                    } catch let failure as ProfileHTTPFailure where failure.needsNativeConfirmation {
                        cliStatus = .unverified;cliStandaloneVerified = false;cliStatusCheckedAt = nil
                        if manual {forceNativeCheck = true}
                        else {
                            publishCurrentCLIRecovery(.authorizationRequired, profile: name, identity: identity, now: now)
                            return .authorizationRequired
                        }
                    } catch is CLIInteractionRequired {
                        publishCurrentCLIRecovery(.authorizationRequired, profile: name, identity: identity, now: now)
                        return .authorizationRequired
                    } catch { return currentCLIRecoveryOutcome ?? .notNeeded }
                }
                if !forceNativeCheck {
                    clearCurrentCLIRecoveryNotice();currentCLIRecoveryOutcome = nil
                    return .notNeeded
                }
            }
            let silentCapability = suppliedSilentCapability ?? (suppliedNative != nil || OfficialCLICurrentRenewal.guaranteesNoSystemPrompt)
            if !manual && !pending && !cliRecoveryNeedsAttention && before.usableAccessToken(now: now) != nil
                && !CLIRenewalInteractionPolicy.mayStartNative(userInitiated:false,
                    backgroundEnabled:allowBackgroundCLIRenewal,guaranteesNoSystemPrompt:silentCapability) {
                // A healthy, merely near-expiry login normally refreshes in the
                // user's existing CLI. Do not manufacture an authorization warning.
                return .notNeeded
            }
            guard currentCLIRenewalPolicy.begin(version: before.digest, now: now, manual: manual) else {
                return currentCLIRecoveryOutcome ?? .notNeeded
            }
            busy = "恢复当前 CLI 登录…"
            defer { busy = nil }
            let clock: () -> Date = isDemo ? { now } : Date.init
            var outcome = try await CLICurrentRecovery.run(target: .init(name: name, identity: identity), io: io, now: clock,
                finishPendingBackup: pending, requestNativeCheck: forceNativeCheck, contextIsCurrent: context,
                gate: gate,
                native: {
                    // Use the same consent gate for fixtures and production.
                    guard CLIRenewalInteractionPolicy.mayStartNative(userInitiated:manual,
                        backgroundEnabled:self.allowBackgroundCLIRenewal,guaranteesNoSystemPrompt:silentCapability) else {
                        return .authorizationRequired
                    }
                    guard self.usageRefreshPolicy.permitsExplicitRequest(profile: name, now: Date()) else { return .temporaryFailure }
                    if let suppliedNative {
                        self.currentCLIRecoveryDidRunNative = true
                        if manual { self.lastRefreshDiagnostics?.nativeHelperRuns += 1 }
                        self.currentCLIBackupPending = CLIProfileIdentity(name: name, identity: identity)
                        return try await suppliedNative()
                    }
                    // Explicit consent is separate from the app's permission to
                    // read a keychain item: a native subprocess may ask macOS UI.
                    self.currentCLIRecoveryDidRunNative = true
                    if manual { self.lastRefreshDiagnostics?.nativeHelperRuns += 1 }
                    self.currentCLIBackupPending = CLIProfileIdentity(name: name, identity: identity)
                    return try await OfficialCLICurrentRenewal.run(home: FileManager.default.homeDirectoryForCurrentUser)
                }, verify: suppliedVerify ?? { CLIIdentity.profile(try await getJSON("profile", $0)) })
            // Native success can leave the same token in place. It is positive
            // evidence worth verifying, unlike a passive metadata tick; finish
            // verification/backup without invoking the native helper again.
            if outcome == .notNeeded && currentCLIRecoveryDidRunNative {
                outcome = try await CLICurrentRecovery.run(target: .init(name: name, identity: identity), io: io, now: clock,
                    finishPendingBackup: true, contextIsCurrent: context, gate: gate,
                    native: { .temporaryFailure },
                    verify: suppliedVerify ?? { CLIIdentity.profile(try await getJSON("profile", $0)) })
            }
            let after = try? owned()
            if let after, try after.identity?.samePrincipal(as: identity) == true { currentCLIObservedLogin = (name, identity, after.digest) }
            currentCLIRenewalPolicy.finish(outcome, version: after?.digest ?? before.digest, now: clock())
            if outcome == .verificationPending || outcome == .backupPending {
                currentCLIBackupPending = CLIProfileIdentity(name: name, identity: identity)
            } else if outcome == .renewed || outcome == .contextChanged || outcome == .needsLogin || outcome == .notNeeded { currentCLIBackupPending = nil }
            else if after == before && !pending { currentCLIBackupPending = nil }
            if outcome == .renewed {
                usageRefreshPolicy.credentialsChanged(profile: name); usageCatchUpPending = true
            }
            if outcome == .contextChanged {
                clearCurrentCLIRecoveryNotice();currentCLIRecoveryOutcome = nil;invalidateCLIStatus()
            } else if try context(), after.map({ (try? $0.identity?.samePrincipal(as: identity)) == true
                || !$0.hasSecrets && outcome == .needsLogin }) == true {
                publishCurrentCLIRecovery(outcome, profile: name, identity: identity, now: clock())
            }
            return outcome
        } catch is CLIInteractionRequired {
            guard (try? context()) == true else { return .contextChanged }
            if let observedIdentity { publishCurrentCLIRecovery(.authorizationRequired, profile: name, identity: observedIdentity, now: now) }
            return .authorizationRequired
        } catch {
            guard (try? context()) == true else { return .contextChanged }
            if let observedIdentity { publishCurrentCLIRecovery(.retryLater, profile: name, identity: observedIdentity, now: now) }
            else { invalidateCLIStatus() }
            return .retryLater
        }
    }

    func refreshAfterLinkedCLIOperation() async {
        usageRefreshPolicy.credentialsChanged(profile: current)
        usageCatchUpPending = true
        await refreshAllStatuses()
    }

    func clearCurrentCLIRecoveryNotice() {
        if banner == currentCLIRecoveryMessage { banner = nil }
        currentCLIRecoveryMessage = nil
    }

    func publishCurrentCLIRecovery(_ outcome: CLICurrentRecoveryOutcome, profile: String, identity: CLIIdentity, now: Date) {
        let previous = currentCLIRecoveryOutcome
        currentCLIRecoveryOutcome = outcome
        cliObservedIdentity = identity; cliProfile = profile; cliEmail = identity.email
        let message: String?
        switch outcome {
        case .renewed:
            cliStatus = protection.desktopScope == .subscription ? .matched : .unverified
            cliStandaloneVerified = protection.desktopScope != .subscription
            cliStatusCheckedAt = now
            cliStatusDetail = currentCLIRecoveryDidRunNative ? "当前默认 CLI 登录已由官方程序恢复，身份已核验，备份已更新。" : nil
            clearCurrentCLIRecoveryNotice(); return
        case .needsLogin:
            cliStatus = .needsLogin
            message = "官方 CLI 无法恢复当前登录，请在 Claude Code 执行 /login；无需先 /logout。"
        case .authorizationRequired:
            cliStatus = .refreshNeeded
            message = "CLI 登录恢复需要授权，请点击底部刷新；不会切换账号。"
        case .backupPending:
            // Online identity already passed. A backup permission failure is
            // not a failed login and must not prevent same-account quota reads.
            cliStatus = protection.desktopScope == .subscription ? .matched : .unverified
            message = "CLI 登录已恢复，但备份尚未保存；请手动刷新完成授权与备份。"
        case .verificationPending:
            cliStatus = .refreshNeeded
            message = "官方 CLI 已更新保存登录，在线核验暂未完成，将稍后重试。"
        case .retryLater:
            cliStatus = .refreshNeeded
            message = "CLI 本次续期未完成，稍后重试；未判定为需要重新登录。"
        case .unsupported:
            cliStatus = .refreshNeeded
            message = "当前官方 CLI 版本或恢复命令不受支持，请先更新 Claude Code。"
        case .contextChanged:
            invalidateCLIStatus(); return
        case .notNeeded: clearCurrentCLIRecoveryNotice(); return
        }
        cliStandaloneVerified = outcome == .backupPending && protection.desktopScope != .subscription
        cliStatusDetail = message; cliStatusCheckedAt = now
        if previous != outcome {
            clearCurrentCLIRecoveryNotice(); currentCLIRecoveryMessage = message
            if banner == nil { banner = message }
        }
    }
}
