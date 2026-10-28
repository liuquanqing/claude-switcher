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

    private func profileDescriptor(_ name: String) async throws -> CLIProfileIdentity {
        guard ProfileTransaction.validName(name), let index = profiles.firstIndex(where: { $0.name == name }) else { throw err("桌面档案不存在或名称无效，未修改登录。") }
        let directory = profileDir(name)
        let kind = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard kind.isDirectory == true, kind.isSymbolicLink != true else { throw err("桌面档案路径不是普通目录，未读取登录。") }
        guard let access = try await token(for: directory, allowExpired: true) else { return CLIProfileIdentity(name: name, identity: nil) }
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

    /// Reads metadata without trusting the marker. Authenticated verification is gated.
    func refreshCLI(verify: Bool = false) async {
        guard !isDemo else { return }
        cliStatus = .unverified; cliStatusDetail = "默认保存身份尚未核验；未检测终端 shell 环境和各项目设置，不代表已运行的 CLI 任务。"
        let configuration = cliConfiguration()
        if !configuration.allowsSubscriptionMutation {
            cliProfile = nil; cliEmail = nil
            cliStatus = configuration.malformed ? .unverified : (configuration.unsupportedStorage ? .unsupportedStorage : .otherAuthentication)
            cliStatusDetail = configuration.explanation
            // File/custom storage blocks mutations, not the CLI's own local query.
            if configuration.unsupportedStorage && !configuration.malformed && !configuration.otherAuthentication && !configuration.customDirectory {
                await readReportedCLIStatus(configuration: configuration)
            }
            return
        }
        let io = NativeCLIStorage()
        do {
            let document = try io.readIdentityDocument()
            let metadata = try CLIIdentity.metadata(CLIJSON.field(document, key: "oauthAccount"))
            cliEmail = metadata?.email
            let matches = profiles.filter { snapshot in
                guard let identity = snapshot.snapshot?.identity, let metadata else { return false }
                return identity.samePrincipal(as: metadata)
            }
            cliProfile = matches.count == 1 ? matches.first?.name : nil
            guard verify else { return }
            let gate = await protection.preflight(target: .cli)
            guard gate.allowed else { return }
            let live = try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
            guard live.hasSecrets else {
                cliStatus = .needsLogin; cliProfile = nil; cliStatusDetail = "当前默认存储没有可用订阅登录，请在 CLI 中登录。"; return
            }
            guard let access = live.usableAccessToken(now: Date()) else {
                cliStatusDetail = "保存的访问凭据需要由 CLI 刷新，再核验默认登录。"; return
            }
            let actual = CLIIdentity.profile(try await getJSON("profile", access))
            guard actual.isComplete, let paired = try live.identity, actual.samePrincipal(as: paired) else {
                cliStatus = .different; cliStatusDetail = "CLI 凭据与身份信息不一致；未保存或覆盖任何登录。"; return
            }
            let candidates = profiles.filter { $0.snapshot?.identity.samePrincipal(as: actual) == true }
            guard candidates.count == 1, let owner = candidates.first else {
                cliProfile = nil; cliStatusDetail = "CLI 身份无法唯一关联到桌面档案。"; return
            }
            cliProfile = owner.name; cliEmail = actual.email
            cliStatus = owner.name == current ? .matched : .different
            cliStatusDetail = "仅核验默认保存登录；未检测终端 shell 环境和各项目设置，不代表已运行的 CLI 任务。"
        } catch {
            cliProfile = nil; cliStatus = .unverified; cliStatusDetail = "CLI 登录核验未完成，未修改登录。"
        }
    }

    private func readReportedCLIStatus(configuration: AuthenticationConfiguration) async {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let marker = try confirmedCurrentProfile()
            let report = try await CLIStatusReader.read(home: home)
            guard report.usesConfigurationDirectory(home.appendingPathComponent(".claude")), !configuration.customDirectory else {
                cliStatus = .unsupportedStorage; cliStatusDetail = "CLI 使用了不同配置目录；未按默认账号猜测配对，未修改登录。"; return
            }
            guard report.loggedIn else {
                cliStatus = .needsLogin; cliStatusDetail = "CLI 本次只读报告默认配置未登录；未执行登录或注销。"; return
            }
            guard report.authMethod == "claude.ai", !configuration.otherAuthentication else {
                cliStatus = .otherAuthentication; cliStatusDetail = "CLI 报告已登录，但不是可自动同步的默认订阅来源；保留现状。"; return
            }
            let document = try NativeCLIStorage().readIdentityDocument()
            let metadata = try CLIIdentity.metadata(CLIJSON.field(document, key: "oauthAccount"))
            let record = report.savedRecord(matching: metadata)
            cliEmail = report.identity.email
            let matches = profiles.filter { profile in
                guard let desktop = profile.snapshot?.identity, let record else { return false }
                return desktop.samePrincipal(as: record)
            }
            cliProfile = matches.count == 1 ? matches.first?.name : nil
            var comparison = "身份记录尚未能完整配对到桌面档案。"
            if marker == current, try confirmedCurrentProfile() == marker, DesktopModeInspector.read(support: support) == .subscription {
                let cached = profiles.first { $0.name == marker }?.snapshot?.identity
                let config = try? CLIJSON.object(Data(contentsOf: liveDir.appendingPathComponent("config.json")))
                let desktop = CLIIdentity(accountID: config?["lastKnownAccountUuid"] as? String ?? cached?.accountID,
                    organizationID: config?["lastKnownOrganizationUuid"] as? String ?? cached?.organizationID, email: cached?.email)
                if let record, desktop.samePrincipal(as: record) {
                    comparison = "账号与组织的保存记录与桌面一致。"
                } else if CLIReportedStatus.sameAccountRecord(record, desktop) == true {
                    comparison = desktop.isComplete && record?.isComplete == true
                        ? "账号 ID 相同，但组织保存记录不同。"
                        : "账号 ID 保存记录与桌面一致；组织仍未确认。"
                } else if CLIReportedStatus.sameAccountRecord(record, desktop) == false {
                    comparison = "CLI 与桌面的账号 ID 保存记录不同。"
                }
            }
            // Keep this weaker than .matched: a local status report cannot prove
            // token validity, the selected storage backend or already running tasks.
            cliStatus = .unverified
            cliStatusDetail = "CLI 已报告订阅登录。" + comparison + "凭据文件的自动同步仍未适配，未改写登录；不代表所有已运行终端任务。"
        } catch {
            cliStatus = .unverified; cliStatusDetail = "CLI 本地状态读取未完成，未修改登录。" + (configuration.explanation ?? "")
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
        await refreshCLI(verify: true)
    }

    func moveTerminal(to target: String) async {
        if isDemo {
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
            let io = NativeCLIStorage(), transaction = CLITransaction(io: io)
            let context = try await cliContext(target: target, io: io)
            let plan = try await transaction.prepare(target: context.0, profiles: context.1,
                remote: { CLIIdentity.profile(try await getJSON("profile", $0)) })
            try transaction.persistOutgoing(plan)
            _ = try transaction.apply(plan)
            await refreshCLI(verify: true)
        } catch { banner = error.localizedDescription; await refreshCLI(verify: false) }
    }
}
