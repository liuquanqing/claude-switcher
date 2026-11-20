import AppKit
import SwitcherCore

enum CLITerminalFailure: LocalizedError {
    case proxyUnavailable
    case proxyChanged
    case route(SafetyDecision)
    case statusTimedOut
    case statusUnconfirmed
    case wrongDirectory
    case otherAuthentication
    case terminalUnavailable

    var title: String {
        switch self {
        case .proxyUnavailable, .proxyChanged, .route: return "cli.routeNotVerified"
        case .statusTimedOut, .statusUnconfirmed, .wrongDirectory: return "cli.statusReadFailed"
        case .otherAuthentication: return "cli.otherAuthentication"
        case .terminalUnavailable: return "cli.terminalUnavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .proxyUnavailable: return "未发现可用的本机 HTTP 代理，未打开终端。"
        case .proxyChanged: return "本机 HTTP 代理已变化，请重试。"
        case .route(let decision): return decision.message
        case .statusTimedOut: return "读取 Claude Code 登录状态超时。"
        case .statusUnconfirmed: return "Claude Code 未返回可确认的登录状态。"
        case .wrongDirectory: return "Claude Code 报告的目录与选择的终端不一致。"
        case .otherAuthentication: return "此目录的 Claude Code 正在使用 API 或其他认证方式。"
        case .terminalUnavailable: return "无法打开系统终端，请确认 Terminal 可用。"
        }
    }
}

enum CLITerminalLaunch {
    static let authOverrides = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "CLAUDE_ENV_FILE", "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"]
    static func environment(home: URL, directory: URL, inherited: [String: String]) -> [String: String] {
        var result = inherited
        for key in authOverrides { result.removeValue(forKey: key) }
        result["HOME"] = home.path
        if directory.standardizedFileURL == home.appendingPathComponent(".claude").standardizedFileURL {
            result.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else { result["CLAUDE_CONFIG_DIR"] = directory.path }
        return result
    }
    static func executable(home: URL) throws -> URL {
        let choices = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
        guard let path = choices.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw SafetyError("未找到本机 Claude CLI，请先安装官方 Claude Code。")
        }
        return path
    }
    static func command(binding: CLIBinding, executable: URL, home: URL, proxy: UsageQueryProxy) throws -> String {
        try binding.validate(home: home)
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let unset = (authOverrides + ["CLAUDE_CONFIG_DIR"]).map { "-u " + $0 }.joined(separator: " ")
        let directory = binding.choice == .isolated ? "CLAUDE_CONFIG_DIR=" + quote(binding.directory.path) + " " : ""
        let routing = proxy.environment([:], bypass: "localhost,127.0.0.1,::1").sorted { $0.key < $1.key }
            .map { $0.key + "=" + quote($0.value) + " " }.joined()
        return "/usr/bin/env " + unset + " " + directory + routing + quote(executable.path)
    }
    static func script(binding: CLIBinding, executable: URL, home: URL, proxy: UsageQueryProxy,
                       intent: CLITerminalIntent = .open, authorizationInstructions: String = "") throws -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launch = try command(binding: binding, executable: executable, home: home, proxy: proxy)
        // The official sign-in runs by itself. Account matching is checked before opening an interactive session.
        let arguments = intent == .signIn ? " --setting-sources '' auth login --claudeai" : ""
        let instructions = intent == .signIn && !authorizationInstructions.isEmpty
            ? "printf '%s\\n\\n' " + quote(authorizationInstructions) + "\n" : ""
        return "#!/bin/zsh\ncd " + quote(home.path) + " || exit 1\n" + instructions + "exec " + launch + arguments + "\n"
    }
    static func readSystemProxy() throws -> UsageQueryProxy {
        let (status, proxyText) = try LocalCommand.run("/usr/sbin/scutil", ["--proxy"])
        guard status == 0, let proxy = try? UsageQueryProxy.system(proxyText) else {
            throw CLITerminalFailure.proxyUnavailable
        }
        return proxy
    }
    static func systemProxy() async throws -> UsageQueryProxy {
        try await Task.detached { try readSystemProxy() }.value
    }
    static let traceEndpoints = NetworkProbe.traceEndpoints + [
        "https://platform.claude.com/cdn-cgi/trace", "https://console.anthropic.com/cdn-cgi/trace"
    ]

    static func traceCountry(endpoint: String, proxy: UsageQueryProxy,
                             run: @Sendable ([String]) async throws -> BoundedCLICommand.Output) async -> String? {
        guard let result = try? await run(["-q", "--silent", "--fail", "--max-time", "8", "--proto", "=https",
            "--proxy", proxy.url, "--noproxy", "", "--write-out", "\n%{http_code}", endpoint]),
            !result.timedOut, result.status == 0 else { return nil }
        let lines = result.text.split(separator: "\n")
        guard let code = lines.last.flatMap({ Int($0) }) else { return nil }
        return NetworkObservation.countryFromTrace(lines.dropLast().joined(separator: "\n"), httpStatus: code)
    }
    @MainActor static func open(binding: CLIBinding, home: URL, proxy: UsageQueryProxy,
                                intent: CLITerminalIntent, authorizationInstructions: String) async throws {
        try binding.validate(home: home)
        let executable = try executable(home: home)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw CLITerminalFailure.terminalUnavailable
        }
        if binding.choice == .isolated {
            try FileManager.default.createDirectory(at: binding.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.claudeswitcher.candidate/CLI Launchers")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let command = cache.appendingPathComponent(UUID().uuidString + ".command")
        try script(binding: binding, executable: executable, home: home, proxy: proxy, intent: intent,
                   authorizationInstructions: authorizationInstructions).write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([command], withApplicationAt: terminal, configuration: config) { _, error in
                if error != nil { continuation.resume(throwing: CLITerminalFailure.terminalUnavailable) }
                else { continuation.resume() }
            }
        }
    }
}

@MainActor extension Store {
    func checkedCLIProxy() async throws -> UsageQueryProxy {
        let proxy = try await CLITerminalLaunch.systemProxy()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probe = NetworkProbe(endpoints: CLITerminalLaunch.traceEndpoints) { endpoint in
            await CLITerminalLaunch.traceCountry(endpoint: endpoint, proxy: proxy) { arguments in
                try await BoundedCLICommand.run(home: home, executable: URL(fileURLWithPath: "/usr/bin/curl"),
                    arguments: arguments, inherited: proxy.environment([:]), timeoutSeconds: 9,
                    graceSeconds: 1, combineStderr: false)
            }
        }
        let gate = await protection.preflight(target: .cli, observe: { mode in await probe.observe(mode: mode) })
        guard gate.allowed else { throw CLITerminalFailure.route(gate) }
        return proxy
    }

    private func prepareCLIConnection(home: URL) async throws -> CLIConnectionAccess {
        guard !updating else { throw SafetyError("应用正在更新，请稍后打开 CLI。") }
        if isDemo {
            return CLIConnectionAccess(status: { $0.choice == .defaultLogin ? .different : .notLoggedIn },
                                       launch: { _, _ in })
        }
        let config = try protection.files.loadConfig()
        let proxy = try await checkedCLIProxy()
        return CLIConnectionAccess(status: { binding in
            try binding.validate(home: home)
            if binding.choice == .isolated {
                try FileManager.default.createDirectory(at: binding.directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let report = try await CLIStatusReader.read(home: home, configurationDirectory: binding.directory,
                                                        proxy: proxy, timeoutSeconds: 12)
            guard report.usesConfigurationDirectory(binding.directory) else { throw CLITerminalFailure.wrongDirectory }
            guard report.authMethod == "claude.ai" || (!report.loggedIn && report.authMethod == "none") else {
                throw CLITerminalFailure.otherAuthentication
            }
            let document = AccountUsageQuery.document(for: binding, home: home)
            let metadata = (try? Data(contentsOf: document)).flatMap { try? CLIIdentity.metadata(CLIJSON.field($0, key: "oauthAccount")) }
            return CLIBindingPolicy.assess(report, binding: binding, metadata: metadata)
        }, launch: { [weak self] binding, intent in
            // Check the listener selection without repeating the remote probes.
            guard try await CLITerminalLaunch.systemProxy() == proxy else {
                throw CLITerminalFailure.proxyChanged
            }
            guard let self, !self.updating, try self.protection.files.loadConfig() == config,
                  try confirmedCurrentProfile() == self.current,
                  self.protection.desktopScope == .subscription,
                  self.active?.snapshot?.identity.samePrincipal(as: binding.identity) == true else {
                throw SafetyError("账号或保护配置已变化，未打开终端。")
            }
            try await CLITerminalLaunch.open(binding: binding, home: home, proxy: proxy, intent: intent,
                authorizationInstructions: appText("cli.authorizationTerminalInstructions", language: self.appLanguage))
        })
    }

    func makeCLIConnection() -> CLIConnectionController {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let repository = CLIBindingRepository(file: protection.files.directory.appendingPathComponent("cli-bindings.json"), home: home)
        var demoBindings: [String: CLIBinding] = [:]
        return CLIConnectionController(operations: .init(context: { [weak self] in
            guard let self, self.protection.desktopScope == .subscription,
                  let identity = self.active?.snapshot?.identity, identity.isComplete else { return nil }
            return CLIConnectionContext(profile: self.current, identity: identity)
        }, load: { [weak self] identity in
            if self?.isDemo == true { return demoBindings[try CLIBinding.key(identity)] }
            return try repository.load(identity)
        }, save: { [weak self] binding in
            if self?.isDemo == true { demoBindings[try CLIBinding.key(binding.identity)] = binding; return }
            try repository.save(binding)
        }, make: { [weak self] choice, identity in
            var directory = try CLIBinding.directory(for: choice, identity: identity, home: home)
            if choice == .isolated, let self, !self.isDemo, self.active?.snapshot?.identity.samePrincipal(as: identity) == true,
               ProfileTransaction.validName(self.current) {
                let existing = home.appendingPathComponent(".claude-switcher-cli").appendingPathComponent(self.current)
                if FileManager.default.fileExists(atPath: existing.path) { directory = existing }
            }
            let binding = CLIBinding(identity: identity, choice: choice, directory: directory)
            if self?.isDemo != true { try binding.validate(home: home) }
            return binding
        }, access: { [weak self] in
            guard let self else { throw CLITerminalFailure.terminalUnavailable }
            return try await self.prepareCLIConnection(home: home)
        }, usesDefaultLogin: { [weak self] identity in
            guard let self else { return false }
            return self.cliObservedIdentity?.samePrincipal(as: identity) == true
                || (self.isDemo && self.cliStatus == .matched && self.cliProfile == self.current)
        }, backupDefaultLogin: { [weak self] expected in
            guard let self else { throw SafetyError("CLI 备份尚未完成。") }
            if self.isDemo { return }
            guard self.current == expected.profile,
                  self.active?.snapshot?.identity.samePrincipal(as: expected.identity) == true else {
                throw SafetyError("账号已变化，未更新 CLI 备份。")
            }
            try await self.backupCurrentDefaultCLI(manual: true)
        }, focusAuthorizationTerminal: { [weak self] in
            if self?.isDemo == true { return true }
            guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first,
                  !terminal.isTerminated else { return false }
            return terminal.isActive || terminal.activate(options: [])
        }, didVerifyLogin: { [weak self] expected, binding in
            self?.clearStaleCLIUsageLoginNotice(profile: expected.profile, identity: binding.identity)
            if binding.choice == .defaultLogin {
                self?.publishLinkedDefaultCLIReport(binding.identity, profile: expected.profile)
            }
        }, localRecord: { [weak self] identity, binding in
            guard let self else { return .unconfirmed }
            if self.isDemo {
                if let binding { return .sameAccount(binding.choice) }
                return self.current == "Personal" ? .sameAccount(.defaultLogin) : .notPrepared
            }
            func metadata(_ url: URL) throws -> CLIIdentity? {
                let data: Data
                do { data = try Data(contentsOf: url) }
                catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
                return try CLIIdentity.metadata(CLIJSON.field(data, key: "oauthAccount"))
            }
            func document(for directory: URL, choice: CLIBindingChoice) -> URL {
                choice == .defaultLogin ? home.appendingPathComponent(".claude.json") : directory.appendingPathComponent(".claude.json")
            }
            do {
                if let binding {
                    let record = try metadata(document(for: binding.directory, choice: binding.choice))
                    if binding.choice == .defaultLogin, record == nil { return .notPrepared }
                    return CLILocalRecordPolicy.assess(binding: binding,
                        bindingMetadata: record,
                        defaultMetadata: nil, isolatedMetadata: nil, expected: identity)
                }
                var isolated: CLIIdentity?
                let candidate = try CLIBinding.directory(for: .isolated, identity: identity, home: home)
                isolated = try metadata(candidate.appendingPathComponent(".claude.json"))
                if isolated == nil, ProfileTransaction.validName(self.current) {
                    isolated = try metadata(home.appendingPathComponent(".claude-switcher-cli/\(self.current)/.claude.json"))
                }
                return CLILocalRecordPolicy.assess(binding: nil, bindingMetadata: nil,
                    defaultMetadata: try metadata(home.appendingPathComponent(".claude.json")),
                    isolatedMetadata: isolated, expected: identity)
            } catch { return .unconfirmed }
        }, hasRecoverableBackup: { [weak self] expected in
            guard let self, !self.isDemo, self.current == expected.profile,
                  ProfileTransaction.validName(expected.profile) else { return false }
            let data = try KeychainReadAccess.read(service: switcherService, account: "cli-" + expected.profile,
                                                   allowInteraction: true)
            return try CLIBackupRecovery.canAttemptRestore(data, expected: expected.identity)
        }, restoreLegacyBackup: { [weak self] expected in
            guard let self else { throw SafetyError("旧 CLI 备份无法恢复。") }
            guard await self.moveTerminal(to: expected.profile, confirmedIdentity: expected.identity) else {
                throw SafetyError(self.banner ?? "旧 CLI 备份无法恢复。")
            }
        }))
    }
}
