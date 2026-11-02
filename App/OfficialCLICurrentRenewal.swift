import Foundation
import Darwin
import SwitcherCore

/// Uses the default native directory and the CLI's own renewal coordination.
/// Never seed a second directory with the current refresh token: existing CLI
/// tasks and the helper must participate in the same native lock.
enum OfficialCLICurrentRenewal {
    // --permission-prompts none controls CLI tool approval, not SecurityAgent.
    // Do not advertise a silent native path until the official runtime offers
    // an enforceable contract which can be validated without real accounts.
    static let guaranteesNoSystemPrompt = false
    static let arguments = ["-p", "/usage", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                            "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "",
                            "--no-session-persistence", "--permission-prompts", "none"]

    static func environment(home: URL, inherited: [String: String]) -> [String: String] {
        let allowed = ["PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                       "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                       "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]
        var result = inherited.filter { allowed.contains($0.key) }
        result["HOME"] = home.path
        result["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        result["DISABLE_TELEMETRY"] = "1"; result["DISABLE_ERROR_REPORTING"] = "1"; result["DISABLE_AUTOUPDATER"] = "1"
        return result
    }

    static func classify(status: Int32, text: String) -> CLINativeRenewalOutcome {
        let value = text.lowercased()
        if value.contains("user interaction is not allowed") || value.contains("errsecinteractionnotallowed")
            || value.contains("keychain access denied") { return .authorizationRequired }
        if value.contains("invalid_grant") || value.contains("oauth session expired and could not be refreshed")
            || value.contains("oauth access token has been revoked") || value.contains("oauth token revoked")
            || value.contains("login expired") && value.contains("/login")
            || value.contains("not logged in") && value.contains("/login") { return .loginRequired }
        if value.contains("unknown option") || value.contains("unknown slash command") { return .unsupported }
        return status == 0 ? .completed : .temporaryFailure
    }

    static func supportsVersion(_ text: String) -> Bool {
        guard let first = text.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        let values = first.split(separator: ".").compactMap { Int($0) }
        guard values.count == 3 else { return false }
        return values[0] > 2 || values[0] == 2 && (values[1] > 1 || values[1] == 1 && values[2] >= 268)
    }

    static func run(home: URL, executable: URL? = nil,
                    inherited: [String: String] = ProcessInfo.processInfo.environment,
                    timeoutSeconds: TimeInterval = 45, graceSeconds: TimeInterval = 2) async throws -> CLINativeRenewalOutcome {
        let choices = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
        guard let executable = executable ?? choices.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return .unsupported }
        let effectiveEnvironment = environment(home: home, inherited: inherited)
        let version = try await BoundedCLICommand.run(home: home, executable: executable, arguments: ["--version"], inherited: effectiveEnvironment,
                                        timeoutSeconds: max(1, min(timeoutSeconds, 10)), graceSeconds: graceSeconds)
        guard !version.timedOut, version.status == 0, supportsVersion(version.text) else { return .unsupported }
        let result = try await BoundedCLICommand.run(home: home, executable: executable, arguments: arguments, inherited: effectiveEnvironment,
                                       timeoutSeconds: timeoutSeconds, graceSeconds: graceSeconds)
        return result.timedOut ? .timedOut : classify(status: result.status, text: result.text)
    }

}
