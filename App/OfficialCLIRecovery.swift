import Foundation
import CryptoKit
import Security
import Darwin
import SwitcherCore

struct CLIRecoveryTimedOut: Error, LocalizedError, Sendable {
    var errorDescription: String? { "官方 CLI 恢复超时，现有资料已保留；若重试仍失败，可能需要重新登录。" }
}

/// An isolated *preparation* directory, not a replacement for the default CLI.
/// All credential I/O and execution are injectable; tests never touch a real keychain.
@MainActor final class OfficialCLIRecovery {
    struct Receipt: Codable {
        let identity: CLIIdentity
        let seedDigest: String
    }
    let root: URL
    let readSecret: (String) throws -> Data?
    let deleteSecret: (String) throws -> Void
    let run: (URL) async throws -> Void

    init(root: URL, readSecret: @escaping (String) throws -> Data?,
         deleteSecret: @escaping (String) throws -> Void,
         run: @escaping (URL) async throws -> Void) {
        self.root = root; self.readSecret = readSecret; self.deleteSecret = deleteSecret; self.run = run
    }

    static func service(for directory: URL) -> String {
        let normalized = directory.path.precomposedStringWithCanonicalMapping
        let suffix = SHA256.hash(data: Data(normalized.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + suffix
    }
    private func secureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isDirectory == true, values.isSymbolicLink != true,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw SafetyError("CLI 恢复目录权限无法确认，未读取或修改登录。")
        }
        var mutableURL = url
        var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true
        try mutableURL.setResourceValues(resourceValues)
    }
    func recover(_ seed: CLIOwnedLogin, expected: CLIIdentity) async throws -> CLIRecoveredLogin {
        guard expected.isComplete, try seed.identity?.samePrincipal(as: expected) == true else {
            throw SafetyError("CLI 恢复目标身份不完整，未修改登录。")
        }
        try secureDirectory(root)
        let key = SHA256.hash(data: Data((expected.accountID! + "\n" + expected.organizationID! + "\n" + seed.digest).utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(key)
        try secureDirectory(directory)
        let receiptURL = directory.appendingPathComponent("switcher-recovery.json")
        let credentialURL = directory.appendingPathComponent(".credentials.json")
        let profileURL = directory.appendingPathComponent(".claude.json")
        let service = Self.service(for: directory)
        func readLogin() throws -> CLIOwnedLogin {
            // Native macOS CLI may promote a file credential into its scoped keychain.
            // That scoped native record takes precedence over the unchanged seed file.
            let primary = try readSecret(service)
            let credentials = try primary ?? CLIPrivateFile.read(credentialURL)
            return try CLIOwnedLogin(credentials: credentials, identityDocument: CLIPrivateFile.read(profileURL))
        }
        if let bytes = try CLIPrivateFile.read(receiptURL) {
            let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
            guard receipt.identity.samePrincipal(as: expected) else {
                throw SafetyError("CLI 恢复资料属于其他账号，未覆盖。")
            }
            let retained = try readLogin()
            guard receipt.seedDigest == seed.digest || retained == seed else {
                throw SafetyError("CLI 备份已变化，请先检查保留的恢复资料。")
            }
            // Preserve native rotation after a failed backup write or an interrupted app.
            if retained.usableAccessToken(now: Date()) != nil {
                return result(retained, directory: directory, service: service)
            }
        } else {
            // Initialization can stop between its private file writes and receipt.
            // Complete only missing, unchanged seed fields; never replace a rotation.
            let partial = try readLogin()
            guard (partial.oauth == nil || partial.oauth == seed.oauth),
                  (partial.metadata == nil || partial.metadata == seed.metadata) else {
                throw SafetyError("CLI 恢复资料尚未完成，已保留；未用旧备份覆盖。")
            }
            if partial.oauth == nil {
                try CLIPrivateFile.write(CLIJSON.replacing(nil, key: "claudeAiOauth", with: seed.oauth), to: credentialURL)
            }
            if partial.metadata == nil {
                try CLIPrivateFile.write(CLIJSON.replacing(nil, key: "oauthAccount", with: seed.metadata), to: profileURL)
            }
            try CLIPrivateFile.write(JSONEncoder().encode(Receipt(identity: expected, seedDigest: seed.digest)), to: receiptURL)
        }
        // Do not delete or reset the workspace on any failure: it may now hold a
        // rotated refresh credential that cannot be reconstructed from the old backup.
        do { try await run(directory) }
        catch let timeout as CLIRecoveryTimedOut { throw timeout }
        catch { throw SafetyError("官方 CLI 自动恢复未完成，恢复资料已保留；请稍后重试。") }
        return result(try readLogin(), directory: directory, service: service)
    }
    private func result(_ login: CLIOwnedLogin, directory: URL, service: String) -> CLIRecoveredLogin {
        CLIRecoveredLogin(login: login, finish: { [self] in
            // If removing the directory fails after scoped-keychain cleanup, its
            // file must hold the renewed login, not the obsolete seed.
            try CLIPrivateFile.write(CLIJSON.replacing(nil, key: "claudeAiOauth", with: login.oauth),
                                     to: directory.appendingPathComponent(".credentials.json"))
            try CLIPrivateFile.write(CLIJSON.replacing(nil, key: "oauthAccount", with: login.metadata),
                                     to: directory.appendingPathComponent(".claude.json"))
            try deleteSecret(service)
            try FileManager.default.removeItem(at: directory)
        })
    }

    static func native(home: URL) -> OfficialCLIRecovery {
        OfficialCLIRecovery(root: home.appendingPathComponent("Library/Application Support/Claude Switcher/CLI-Recovery"),
            readSecret: { service in
                try KeychainReadAccess.read(service: service, account: NSUserName(), allowInteraction: true)
            }, deleteSecret: { service in
                let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
                    kSecAttrService as String:service, kSecAttrAccount as String:NSUserName()]
                let code = SecItemDelete(query as CFDictionary)
                guard code == errSecSuccess || code == errSecItemNotFound else { throw SafetyError("CLI 恢复资料清理待完成。") }
            }, run: { directory in try await runOfficial(home: home, directory: directory) })
    }

    nonisolated static func childEnvironment(home: URL, directory: URL, inherited: [String:String]) -> [String:String] {
        // Preserve proxy routing, not ambient providers or project authentication.
        let allowed = ["PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                       "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                       "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]
        var env = inherited.filter { allowed.contains($0.key) }
        env["HOME"] = home.path; env["CLAUDE_CONFIG_DIR"] = directory.path
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        env["DISABLE_TELEMETRY"] = "1"; env["DISABLE_ERROR_REPORTING"] = "1"; env["DISABLE_AUTOUPDATER"] = "1"
        // Respect an explicit no-network CLI preference: its old cache must fail
        // later validation, rather than silently overriding the user's setting.
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = inherited["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]
        return env
    }
    static func runOfficial(home: URL, directory: URL,
                            inherited: [String:String] = ProcessInfo.processInfo.environment,
                            timeoutSeconds: TimeInterval = 45, terminationGrace: TimeInterval = 5) async throws {
        try await Task.detached(priority: .userInitiated) {
            let choices = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
            guard let executable = choices.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw SafetyError("未找到本机官方 Claude CLI，未修改登录。")
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-p", "/usage", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "", "--no-session-persistence", "--permission-prompts", "none"]
            process.currentDirectoryURL = directory
            process.environment = childEnvironment(home: home, directory: directory, inherited: inherited)
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            // Foundation waitUntilExit can hang after a Swift task resumes on
            // another worker thread. Complete through Process's exit callback.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
                let forceStop = DispatchWorkItem {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                process.terminationHandler = { child in
                    terminate.cancel(); forceStop.cancel()
                    child.terminationHandler = nil
                    if Date() >= deadline { continuation.resume(throwing: CLIRecoveryTimedOut()) }
                    else if child.terminationReason == .exit && child.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: SafetyError("官方 CLI 自动恢复未完成。")) }
                }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: terminate)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds + terminationGrace, execute: forceStop)
                } catch {
                    process.terminationHandler = nil
                    terminate.cancel(); forceStop.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }.value
    }
}
