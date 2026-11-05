import AppKit
import SwitcherCore

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
    static func command(binding: CLIBinding, executable: URL, home: URL) throws -> String {
        try binding.validate(home: home)
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let unset = (authOverrides + ["CLAUDE_CONFIG_DIR"]).map { "-u " + $0 }.joined(separator: " ")
        let directory = binding.choice == .isolated ? "CLAUDE_CONFIG_DIR=" + quote(binding.directory.path) + " " : ""
        return "/usr/bin/env " + unset + " " + directory + quote(executable.path)
    }
    static func script(binding: CLIBinding, executable: URL, home: URL) throws -> String {
        let homeQuoted = "'" + home.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/zsh\ncd " + homeQuoted + " || exit 1\nexec " + (try command(binding: binding, executable: executable, home: home)) + "\n"
    }
    @MainActor static func open(binding: CLIBinding, home: URL) async throws {
        try binding.validate(home: home)
        let executable = try executable(home: home)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw SafetyError("无法打开终端，请确认 Terminal 可用。")
        }
        if binding.choice == .isolated {
            try FileManager.default.createDirectory(at: binding.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.claudeswitcher.candidate/CLI Launchers")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let command = cache.appendingPathComponent(UUID().uuidString + ".command")
        try script(binding: binding, executable: executable, home: home).write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([command], withApplicationAt: terminal, configuration: config) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

@MainActor extension Store {
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
        }, status: { [weak self] binding in
            guard let self else { return .unconfirmed }
            guard !self.updating else { throw SafetyError("应用正在更新，请稍后打开 CLI。") }
            if self.isDemo { return binding.choice == .defaultLogin ? .different : .notLoggedIn }
            try binding.validate(home: home)
            let gate = await self.protection.preflight(target: .cli)
            guard gate.allowed else { throw SafetyError(gate.message) }
            if binding.choice == .isolated {
                try FileManager.default.createDirectory(at: binding.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let report = try await CLIStatusReader.read(home: home, configurationDirectory: binding.directory, timeoutSeconds: 25)
            let document = binding.choice == .defaultLogin ? home.appendingPathComponent(".claude.json") : binding.directory.appendingPathComponent(".claude.json")
            let metadata = (try? Data(contentsOf: document)).flatMap { try? CLIIdentity.metadata(CLIJSON.field($0, key: "oauthAccount")) }
            return CLIBindingPolicy.assess(report, binding: binding, metadata: metadata)
        }, launch: { [weak self] binding in
            guard let self else { return }
            guard !self.updating else { throw SafetyError("应用正在更新，请稍后打开 CLI。") }
            if self.isDemo { return }
            let gate = await self.protection.preflight(target: .cli)
            guard gate.allowed else { throw SafetyError(gate.message) }
            try await CLITerminalLaunch.open(binding: binding, home: home)
        }, existingDirectory: { [weak self] binding in
            guard self?.isDemo != true else { return false }
            return FileManager.default.fileExists(atPath: binding.directory.path)
        }))
    }
}
