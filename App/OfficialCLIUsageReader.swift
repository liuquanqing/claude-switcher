import Foundation
import SwitcherCore

enum OfficialCLIUsageReader {
    /// Automatic reads inspect only the native JSON cache. Only a manual request
    /// starts one unmodified CLI. This adapter does not read OAuth credentials.
    /// The separate automatic adapter uses only noninteractive, already-authorized reads.
    static func read(home: URL, manual: Bool, now: Date = Date(),
                     environment inherited: [String: String] = ProcessInfo.processInfo.environment) async throws -> OfficialCLIUsageCache? {
        try await Task.detached(priority: .utility) {
            let custom = inherited["CLAUDE_CONFIG_DIR"] ?? ""
            guard custom.isEmpty else { throw SafetyError("检测到自定义 CLI 目录，未按默认账号查询额度。") }
            let file = home.appendingPathComponent(".claude.json")
            func document() throws -> Data? {
                do { return try Data(contentsOf: file) }
                catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
            }
            guard let before = try document(), let identity = try OfficialCLIUsageCache.identity(in: before), identity.isComplete else {
                throw SafetyError("默认官方 CLI 登录身份尚未确认，请先在 Claude Code 中完成登录。")
            }
            let cached = try? OfficialCLIUsageCache.read(before)
            guard manual else { return try OfficialCLIUsageCache.read(before) }
            if let cached, (0..<30).contains(now.timeIntervalSince(cached.fetchedAt)) { return cached }
            let paths = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
            guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw SafetyError("未找到本机官方 Claude CLI，保留用量缓存。")
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-cli-usage-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-p", "/usage", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                                 "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "", "--no-session-persistence",
                                 "--permission-prompts", "none"]
            process.currentDirectoryURL = temporary
            var environment = inherited
            // The helper reads the default native subscription, never a shell's
            // alternate key/router, and never changes any of the user's settings.
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE",
                        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
                environment.removeValue(forKey: key)
            }
            environment["HOME"] = home.path
            environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
            environment["DISABLE_TELEMETRY"] = "1"
            environment["DISABLE_ERROR_REPORTING"] = "1"
            environment["DISABLE_AUTOUPDATER"] = "1"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
            defer { timeout.cancel() }
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw SafetyError("官方 CLI 暂未完成用量读取，原缓存和登录保持原样。")
            }
            guard let after = try document(), let finalIdentity = try OfficialCLIUsageCache.identity(in: after),
                  finalIdentity.samePrincipal(as: identity) else {
                throw SafetyError("读取期间默认 CLI 账号发生变化，未采纳用量结果。")
            }
            return try OfficialCLIUsageCache.read(after)
        }.value
    }
}
