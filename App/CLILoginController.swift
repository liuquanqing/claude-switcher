import Foundation
import SwitcherCore

@MainActor extension Store {
    func cliConfiguration(cwd: URL = FileManager.default.homeDirectoryForCurrentUser) -> AuthenticationConfiguration {
        AuthenticationConfiguration.read(home: FileManager.default.homeDirectoryForCurrentUser,
                                         cwd: cwd, environment: ProcessInfo.processInfo.environment)
    }
    private func requireSupportedCLI() throws {
        let config = cliConfiguration()
        guard config.allowsSubscriptionMutation else { throw SafetyError(config.explanation ?? "CLI 认证配置未确认。") }
    }

    /// Authorization can take time. Recheck the route immediately before any
    /// authenticated identity request, rather than reusing the pre-dialog result.
    func checkedCLIIdentity(_ token: String,
                            fetch: (String) async throws -> CLIIdentity = { CLIIdentity.profile(try await getJSON("profile", $0)) }) async throws -> CLIIdentity {
        let decision = await protection.preflight(target: .cli)
        guard decision.allowed else { throw SafetyError(decision.message) }
        return try await fetch(token)
    }

    func profileDescriptor(_ name: String, allowInteraction: Bool = true) async throws -> CLIProfileIdentity {
        guard ProfileTransaction.validName(name), profiles.contains(where: { $0.name == name }) else { throw err("桌面档案不存在或名称无效，未修改登录。") }
        let originalMarker = try confirmedCurrentProfile()
        let directory = profileDir(name)
        let kind = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard kind.isDirectory == true, kind.isSymbolicLink != true else { throw err("桌面档案路径不是普通目录，未读取登录。") }
        guard let access = try await token(for: directory, allowExpired: true, allowInteraction: allowInteraction) else { return CLIProfileIdentity(name: name, identity: nil) }
        let config = try CLIJSON.object(Data(contentsOf: directory.appendingPathComponent("config.json")))
        let localAccount = config["lastKnownAccountUuid"] as? String
        if let snapshot = profiles.first(where: { $0.name == name })?.snapshot, snapshot.identity.isComplete,
           snapshot.identityTokenDigest == desktopTokenDigest(access),
           localAccount == nil || localAccount == snapshot.identity.accountID {
            guard try confirmedCurrentProfile() == originalMarker else { throw err("读取期间桌面账号发生变化，未采纳旧身份。") }
            return CLIProfileIdentity(name: name, identity: snapshot.identity)
        }
        let identity: CLIIdentity
        var observedProfile: [String: Any]?
        do {
            identity = try await checkedCLIIdentity(access) { access in
                let value = try await getJSON("profile", access)
                observedProfile = value
                return CLIIdentity.profile(value)
            }
        }
        catch let failure as SafetyError { throw failure }
        catch { throw err("桌面档案“\(name)”的保存身份未能确认；未移动目录，请先在原客户端确认登录。") }
        guard identity.isComplete, localAccount == nil || localAccount == identity.accountID else {
            throw err("桌面保存身份与档案标识不一致，未修改登录；请先在原客户端确认该档案。")
        }
        guard try confirmedCurrentProfile() == originalMarker,
              try await token(for: directory, allowExpired: true, allowInteraction: allowInteraction) == access else {
            throw err("读取期间桌面账号发生变化，未采纳旧身份。")
        }
        try applyVerifiedDesktopIdentity(name: name, identity: identity, tokenDigest: desktopTokenDigest(access),
                                         plan: planName(observedProfile?["organization"] as? [String: Any]))
        return CLIProfileIdentity(name: name, identity: identity)
    }

    private func cliContext(target: String, io: NativeCLIStorage) async throws -> (CLIProfileIdentity, [CLIProfileIdentity]) {
        let originalCurrent = try confirmedCurrentProfile()
        guard ProfileTransaction.validName(target) else {
            throw err("档案名称或标记无效，未读取或修改登录。")
        }
        try requireSupportedCLI()
        if cliConfiguration().fileCredentialsPresent {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let report = try await CLIStatusReader.read(home: home)
            guard report.usesConfigurationDirectory(home.appendingPathComponent(".claude")),
                  (report.loggedIn && report.authMethod == "claude.ai") || (!report.loggedIn && report.authMethod == "none") else {
                throw SafetyError("官方 CLI 未确认默认订阅配置目录；未备份或改写登录。")
            }
        }
        let live = try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
        let metadata = try live.identity
        let targetHasBackup = try io.containsBackup(target)
        var descriptors = profiles.map { CLIProfileIdentity(name: $0.name, identity: $0.snapshot?.identity) }
        let needingIdentity = profiles.filter { profile in
            profile.name == originalCurrent || (targetHasBackup && profile.name == target)
                || (metadata?.email != nil && profile.snapshot?.email == metadata?.email)
                || (metadata.map { profile.snapshot?.identity.samePrincipal(as: $0) == true } ?? false)
        }.map(\.name)
        for name in needingIdentity {
            let descriptor = try await profileDescriptor(name)
            if let index = descriptors.firstIndex(where: { $0.name == name }) { descriptors[index] = descriptor }
        }
        guard try confirmedCurrentProfile() == originalCurrent else { throw err("桌面档案在核验期间变化，未修改账号。") }
        guard let destination = descriptors.first(where: { $0.name == target }) else { throw err("目标桌面档案不存在。") }
        return (destination, descriptors)
    }

    func performLinkedDesktopSwitch(from source: String, to target: String) async throws {
        try ProfileTransaction(live: liveDir, parked: parkDir, marker: currentFile).validate(from: source, to: target)
        let destinationDirectory = profileDir(target)
        func targetIsSubscription() throws -> Bool {
            let path = destinationDirectory.appendingPathComponent("claude_desktop_config.json")
            do { return DesktopModeInspector.classify([try Data(contentsOf: path)]) == .subscription }
            catch let e as CocoaError where e.code == .fileReadNoSuchFile { return true }
        }
        guard try targetIsSubscription() else { throw err("目标档案为 API 或模式无法确认，未切换；请使用原工具管理模式。") }
        let io = NativeCLIStorage(), transaction = CLITransaction(io: io)
        busy = "核验 CLI 归属与目标备份…"
        let context: (CLIProfileIdentity, [CLIProfileIdentity])
        do { context = try await cliContext(target: target, io: io) }
        catch { throw CLIPreparationFailure(error.localizedDescription) }
        try await prepareTargetCLIRecovery(target: context.0, io: io)
        let restoration = try await CLILinkedSwitch.run(transaction: transaction, target: context.0, profiles: context.1, requiresTargetLogin: true,
            remote: { try await self.checkedCLIIdentity($0) },
            quit: {
                guard try confirmedCurrentProfile() == source else { throw err("桌面档案已被外部切换，未移动目录。") }
                // Keychain authorization/backup can outlast the initial route check.
                // Stop here before closing the old desktop if its route is now unknown.
                let decision = await self.protection.preflight()
                guard decision.allowed else { throw SafetyError(decision.message) }
                self.busy = "正在退出 Claude…"
                return await quitClaude()
            }, move: {
                guard try confirmedCurrentProfile() == source else { throw err("桌面档案已被外部切换，未移动目录。") }
                guard DesktopModeInspector.read(support: support) == .subscription, try targetIsSubscription() else {
                    throw err("桌面模式在准备期间变化，未移动目录。")
                }
                self.busy = "正在切换账号并恢复 CLI…"
                return try ProfileTransaction(live: liveDir, parked: parkDir, marker: currentFile).activate(from: source, to: target)
            })
        reloadList()
        await refreshCLI(verify: false)
        presentCLIRestoration(restoration, target: target, identity: context.0.identity)
    }

    /// The transaction already verified identity and read back the restored login.
    /// Publish that completed result without another credential read or password prompt.
    func presentCLIRestoration(_ restoration: CLIRestoration, target: String, identity: CLIIdentity?) {
        guard current == target, cliProfile == target,
              let identity, cliObservedIdentity?.samePrincipal(as: identity) == true else { return }
        if restoration == .verifiedLogin {
            cliStatus = .matched; cliStatusCheckedAt = Date(); cliStandaloneVerified = false
            cliStatusDetail = "仅核验默认保存登录；未检测终端 shell 环境和各项目设置，不代表已运行的 CLI 任务。"
        } else if restoration == .storedLogin {
            cliStatus = .unverified; cliStatusCheckedAt = nil
            cliStatusDetail = "已回读确认保存登录，访问凭据需由 CLI 刷新后再核验。"
        }
    }

    private func prepareTargetCLIRecovery(target: CLIProfileIdentity, io: NativeCLIStorage) async throws {
        let native = OfficialCLIRecovery.native(home: FileManager.default.homeDirectoryForCurrentUser)
        do {
            _ = try await CLIBackupRecovery.prepare(target: target, io: io, renew: { login, identity in
                let decision = await self.protection.preflight(target: .cli)
                guard decision.allowed else { throw SafetyError(decision.message) }
                self.busy = "正在恢复 CLI 登录…"
                return try await native.recover(login, expected: identity)
            }, remote: { token in try await self.checkedCLIIdentity(token) })
        } catch let failure as CLIRecoveryPersistenceFailure { throw failure }
        catch { throw CLIPreparationFailure(error.localizedDescription) }
    }

    /// Complete a display-only refresh without replacing known results with a transient state.
    /// The operation remains injectable so tests use fictional data, never the live login stores.
    func updateCLIStatus(using operation: () async -> CLIStatusPresentation) async {
        guard !cliStatusRefreshing else { return }
        let profileAtStart = current
        let generationAtStart = cliStatusGeneration
        cliStatusRefreshing = true
        defer { cliStatusRefreshing = false }
        let result = await operation()
        guard current == profileAtStart, cliStatusGeneration == generationAtStart else { invalidateCLIStatus(); return }
        let sameIdentity = result.identity.map { cliObservedIdentity?.samePrincipal(as: $0) == true } ?? false
        let sameProfile = result.profile == cliProfile
            || (cliProfile == nil && cliStatus == .reported && result.profile == current)
        if sameIdentity && sameProfile && result.metadataOnly && result.status != .different && cliRecoveryNeedsAttention {
            return // Metadata alone cannot erase an explicit recovery failure.
        }
        let preserveCompleted = sameIdentity && sameProfile && result.status != .different
            && (result.metadataOnly && (cliStandaloneVerified || cliStatus == .reported || cliStatus == .matched && result.profile == current)
                || result.status == .reported && cliStatus == .matched && result.profile == current)
        cliObservedIdentity = result.identity
        if preserveCompleted {
            cliProfile = result.profile; cliEmail = result.email
            return // Retain the original verification time; metadata is not a new check.
        }
        cliProfile = result.profile; cliEmail = result.email; cliStatusDetail = result.detail
        cliStatus = result.status; cliStandaloneVerified = result.standaloneVerified; cliStatusCheckedAt = result.metadataOnly ? nil : Date()
    }

    func invalidateCLIStatus() {
        cliStatusGeneration += 1
        cliObservedIdentity = nil
        cliProfile = nil; cliEmail = nil; cliStatusDetail = nil
        cliStatus = .unverified; cliStandaloneVerified = false; cliStatusCheckedAt = nil
    }

    func observeCLIStatusScope() {
        cliScopeObservation = protection.$desktopScope.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.invalidateCLIStatus()
        }
    }

    /// Network verification is still gated. Only its final result is published to the UI.
    func refreshCLI(verify: Bool = false, allowInteraction: Bool = false) async {
        guard !isDemo else { return }
        // Metadata observations retain stronger completed results only while the
        // account and organization still match; external login changes invalidate them.
        await updateCLIStatus { await evaluateCLIStatus(verify: verify, allowInteraction: allowInteraction) }
    }

    private func evaluateCLIStatus(verify: Bool, allowInteraction: Bool) async -> CLIStatusPresentation {
        var result = CLIStatusPresentation()
        result.detail = "默认保存身份尚未核验；未检测终端 shell 环境和各项目设置，不代表已运行的 CLI 任务。"
        let configuration = cliConfiguration()
        if !configuration.allowsSubscriptionMutation {
            result.profile = nil; result.email = nil
            result.status = configuration.malformed ? .unverified : (configuration.unsupportedStorage ? .unsupportedStorage : .otherAuthentication)
            result.detail = configuration.explanation
            return result
        }
        if configuration.fileCredentialsPresent && allowInteraction {
            let reported = await reportedCLIStatus(configuration: configuration)
            result = reported.presentation
            guard verify, reported.defaultSubscription else { return result }
        }
        let io = NativeCLIStorage(allowInteraction: allowInteraction)
        do {
            let document = try io.readIdentityDocument()
            let metadata = try CLIIdentity.metadata(CLIJSON.field(document, key: "oauthAccount"))
            result.email = metadata?.email
            result.identity = metadata
            let matches = profiles.filter { snapshot in
                guard let identity = snapshot.snapshot?.identity, let metadata else { return false }
                return identity.samePrincipal(as: metadata)
            }
            result.profile = matches.count == 1 ? matches.first?.name : nil
            guard verify else {
                result.detail = nil; result.metadataOnly = true
                if protection.desktopScope == .subscription, let metadata, metadata.isComplete,
                   let desktop = profiles.first(where: { $0.name == current })?.snapshot?.identity,
                   desktop.isComplete, !metadata.samePrincipal(as: desktop) { result.status = .different }
                return result
            }
            let gate = await protection.preflight(target: .cli)
            guard gate.allowed else { result.detail = gate.message; return result }
            let live = try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
            guard live.hasSecrets else {
                result.status = .needsLogin; result.profile = nil; result.detail = "当前默认存储没有可用订阅登录，请在 CLI 中登录。"; return result
            }
            guard let access = live.usableAccessToken(now: Date()) else {
                result.status = .refreshNeeded
                result.detail = "保存凭据待 CLI 刷新；不代表终端已退出登录。"; return result
            }
            let actual = try await checkedCLIIdentity(access)
            guard try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument()) == live else {
                throw SafetyError("CLI 登录在核验期间变化；请重新检查，未修改登录。")
            }
            guard actual.isComplete, let paired = try live.identity, actual.samePrincipal(as: paired) else {
                result.status = .different; result.detail = "CLI 凭据与身份信息不一致；未保存或覆盖任何登录。"; return result
            }
            let marker = try confirmedCurrentProfile()
            if DesktopModeInspector.read(support: support) == .subscription {
                let desktop = try await profileDescriptor(marker, allowInteraction: allowInteraction)
                guard marker == current, try confirmedCurrentProfile() == marker, let identity = desktop.identity, identity.isComplete else {
                    throw SafetyError("桌面身份在检查期间变化或未确认；未同步登录。")
                }
                guard try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument()) == live else {
                    throw SafetyError("CLI 登录在桌面核验期间变化；请重新检查，未修改登录。")
                }
                let candidates = profiles.filter { $0.snapshot?.identity.samePrincipal(as: actual) == true }
                result.profile = candidates.count == 1 ? candidates.first?.name : nil
                result.email = actual.email
                result.status = identity.samePrincipal(as: actual) ? .matched : .different
            } else {
                result.email = actual.email; result.profile = nil
                result.standaloneVerified = true
                result.detail = "默认 CLI 订阅身份已经远端核验；未检测终端 shell 环境和各项目设置。"
                return result
            }
            result.detail = "仅核验默认保存登录；未检测终端 shell 环境和各项目设置，不代表已运行的 CLI 任务。"
        } catch {
            result.profile = nil; result.status = .unverified
            result.detail = (error as? SafetyError)?.localizedDescription ?? "CLI 登录核验未完成，未修改登录。"
        }
        return result
    }

    private func reportedCLIStatus(configuration: AuthenticationConfiguration) async -> (presentation: CLIStatusPresentation, defaultSubscription: Bool) {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let report = try await CLIStatusReader.read(home: home)
            var result = CLIStatusPresentation.localReport(report, expectedDirectory: home.appendingPathComponent(".claude"), configuration: configuration)
            if result.defaultSubscription {
                let document = try? Data(contentsOf: claudeJSON)
                let metadata = try? CLIIdentity.metadata(CLIJSON.field(document, key: "oauthAccount"))
                let identity = report.savedRecord(matching: metadata) ?? report.identity
                result.presentation.identity = identity
                let matches = profiles.filter { $0.snapshot?.identity.samePrincipal(as: identity) == true }
                result.presentation.profile = matches.count == 1 ? matches.first?.name : nil
            }
            return result
        } catch {
            var result = CLIStatusPresentation()
            result.detail = (error as? SafetyError)?.localizedDescription ?? "CLI 状态读取失败，请重试。"
            return (result, false)
        }
    }

    func verifyDefaultCLI() async {
        guard !updating, busy == nil, !refreshing else { return }
        busy = "核验默认 CLI 登录…"; defer { busy = nil }
        if isDemo {
            let gate = await protection.preflight(target: .cli)
            guard gate.allowed else { banner = gate.message; return }
            cliStatus = cliProfile == nil ? .needsLogin : (cliProfile == current ? .matched : .different)
            return
        }
        await updateCLIStatus { (await reportedCLIStatus(configuration: cliConfiguration())).presentation }
    }

    func moveTerminal(to target: String) async {
        guard !updating else { return }
        if isDemo {
            guard protection.desktopScope == .subscription else { banner = "API 或未知桌面模式不执行订阅账号同步。"; return }
            let gate = await protection.preflight(target: .cli)
            guard gate.allowed else { banner = gate.message; return }
            banner = nil; cliProfile = target; cliEmail = profiles.first { $0.name == target }?.snapshot?.email
            cliStatus = cliEmail == nil ? .needsLogin : .matched; return
        }
        guard busy == nil, !refreshing, !statusRefreshInProgress else { return }
        banner = nil; busy = "检查网络与默认 CLI 登录…"
        defer { busy = nil }
        let gate = await protection.preflight(target: .cli)
        guard gate.allowed else { banner = gate.message; return }
        do {
            guard target == current, try confirmedCurrentProfile() == target,
                  DesktopModeInspector.read(support: support) == .subscription else {
                throw SafetyError("只支持同步到当前订阅桌面账号；API 或未知模式不执行同步。")
            }
            let io = NativeCLIStorage(), transaction = CLITransaction(io: io)
            let context = try await cliContext(target: target, io: io)
            try await prepareTargetCLIRecovery(target: context.0, io: io)
            let plan = try await transaction.prepare(target: context.0, profiles: context.1, requiresTargetLogin: true,
                remote: { try await self.checkedCLIIdentity($0) })
            try transaction.persistOutgoing(plan)
            guard try confirmedCurrentProfile() == target, DesktopModeInspector.read(support: support) == .subscription else {
                throw SafetyError("桌面账号或模式在同步期间变化，已保留备份，未覆盖 CLI 登录。")
            }
            let restoration = try transaction.apply(plan)
            await refreshCLI(verify: false)
            presentCLIRestoration(restoration, target: target, identity: context.0.identity)
            busy = nil
            await refreshAfterLinkedCLIOperation()
        } catch { banner = error.localizedDescription; await refreshCLI(verify: false) }
    }
}
