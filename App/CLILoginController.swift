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

    private func profileDescriptor(_ name: String, allowInteraction: Bool = true) async throws -> CLIProfileIdentity {
        guard ProfileTransaction.validName(name), let index = profiles.firstIndex(where: { $0.name == name }) else { throw err("桌面档案不存在或名称无效，未修改登录。") }
        let directory = profileDir(name)
        let kind = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard kind.isDirectory == true, kind.isSymbolicLink != true else { throw err("桌面档案路径不是普通目录，未读取登录。") }
        guard let access = try await token(for: directory, allowExpired: true, allowInteraction: allowInteraction) else { return CLIProfileIdentity(name: name, identity: nil) }
        let config = try CLIJSON.object(Data(contentsOf: directory.appendingPathComponent("config.json")))
        let localAccount = config["lastKnownAccountUuid"] as? String
        if let snapshot = profiles[index].snapshot, snapshot.identity.isComplete,
           snapshot.identityTokenDigest == desktopTokenDigest(access),
           localAccount == nil || localAccount == snapshot.identity.accountID {
            return CLIProfileIdentity(name: name, identity: snapshot.identity)
        }
        let response: [String: Any]
        do { response = try await getJSON("profile", access) }
        catch { throw err("桌面档案“\(name)”的保存身份未能确认；未移动目录，请先在原客户端确认登录。") }
        let identity = CLIIdentity.profile(response)
        guard identity.isComplete, localAccount == nil || localAccount == identity.accountID else {
            throw err("桌面保存身份与档案标识不一致，未修改登录；请先在原客户端确认该档案。")
        }
        var snapshot = profiles[index].snapshot ?? Snapshot(fetchedAt: .distantPast)
        snapshot.accountID = identity.accountID; snapshot.organizationID = identity.organizationID; snapshot.email = identity.email
        snapshot.identityTokenDigest = desktopTokenDigest(access)
        profiles[index].snapshot = snapshot; saveCache(name, snapshot)
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
        let targetHasBackup = try io.readBackup(target) != nil
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
        let restoration = try await CLILinkedSwitch.run(transaction: transaction, target: context.0, profiles: context.1,
            remote: { CLIIdentity.profile(try await getJSON("profile", $0)) },
            quit: {
                guard try confirmedCurrentProfile() == source else { throw err("桌面档案已被外部切换，未移动目录。") }
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
        if restoration == .needsLogin {
            cliStatus = .needsLogin; cliStatusDetail = "目标没有保存的 CLI 登录；桌面可登录，CLI 需完成首次登录。"
        } else if restoration == .storedLogin {
            cliStatus = .unverified; cliStatusDetail = "已回读确认保存登录，访问凭据需由 CLI 刷新后再核验。"
        }
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
        cliProfile = result.profile; cliEmail = result.email; cliStatusDetail = result.detail
        cliStatus = result.status; cliStandaloneVerified = result.standaloneVerified; cliStatusCheckedAt = Date()
    }

    func invalidateCLIStatus() {
        cliStatusGeneration += 1
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
        // Keep an explicitly requested local report with its original timestamp.
        // Profile/mode changes invalidate it; periodic refresh must not replace it
        // with weaker saved metadata or silently start another auth command.
        if !verify && cliStatus == .reported { return }
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
            let matches = profiles.filter { snapshot in
                guard let identity = snapshot.snapshot?.identity, let metadata else { return false }
                return identity.samePrincipal(as: metadata)
            }
            result.profile = matches.count == 1 ? matches.first?.name : nil
            guard verify else { return result }
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
            let actual = CLIIdentity.profile(try await getJSON("profile", access))
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
                let matches = profiles.filter { $0.snapshot?.identity.samePrincipal(as: report.identity) == true }
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
        guard busy == nil, !refreshing else { return }
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
        if isDemo {
            guard protection.desktopScope == .subscription else { banner = "API 或未知桌面模式不执行订阅账号同步。"; return }
            let gate = await protection.preflight(target: .cli)
            guard gate.allowed else { banner = gate.message; return }
            banner = nil; cliProfile = target; cliEmail = profiles.first { $0.name == target }?.snapshot?.email
            cliStatus = cliEmail == nil ? .needsLogin : .matched; return
        }
        guard busy == nil, !refreshing else { return }
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
            let plan = try await transaction.prepare(target: context.0, profiles: context.1, requiresTargetLogin: true,
                remote: { CLIIdentity.profile(try await getJSON("profile", $0)) })
            try transaction.persistOutgoing(plan)
            guard try confirmedCurrentProfile() == target, DesktopModeInspector.read(support: support) == .subscription else {
                throw SafetyError("桌面账号或模式在同步期间变化，已保留备份，未覆盖 CLI 登录。")
            }
            _ = try transaction.apply(plan)
            await refreshCLI(verify: true)
        } catch { banner = error.localizedDescription; await refreshCLI(verify: false) }
    }
}
