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
                       "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]
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
        let version = try await command(home: home, executable: executable, arguments: ["--version"], inherited: inherited,
                                        timeoutSeconds: max(1, min(timeoutSeconds, 10)), graceSeconds: graceSeconds)
        guard !version.timedOut, version.status == 0, supportsVersion(version.text) else { return .unsupported }
        let result = try await command(home: home, executable: executable, arguments: arguments, inherited: inherited,
                                       timeoutSeconds: timeoutSeconds, graceSeconds: graceSeconds)
        return result.timedOut ? .timedOut : classify(status: result.status, text: result.text)
    }

    private struct Output: Sendable { let status: Int32; let text: String; let timedOut: Bool }
    private static func command(home: URL, executable: URL, arguments: [String], inherited: [String: String],
                                timeoutSeconds: TimeInterval, graceSeconds: TimeInterval) async throws -> Output {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-current-cli-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.environment = environment(home: home, inherited: inherited)
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = output
            let fd = output.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw SafetyError("官方 CLI 输出通道不可用。") }
            let queue = DispatchQueue(label: "switcher.current-cli-output")
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            // Drain on a single queue. Keep bounded diagnostic text in memory
            // only, and return a classification rather than the raw output.
            let capture = RenewalOutputCapture()
            source.setEventHandler { capture.drain(fd) }
            source.setCancelHandler { try? output.fileHandleForReading.close() }
            source.resume()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
                let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
                let forceStop = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                process.terminationHandler = { child in
                    terminate.cancel(); forceStop.cancel(); child.terminationHandler = nil
                    queue.async {
                        capture.drain(fd); source.cancel()
                        let result = Output(status: child.terminationStatus, text: capture.text,
                                            timedOut: ProcessInfo.processInfo.systemUptime >= deadline)
                        continuation.resume(returning: result)
                    }
                }
                do {
                    try process.run()
                    try? output.fileHandleForWriting.close()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: terminate)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds + graceSeconds, execute: forceStop)
                } catch {
                    process.terminationHandler = nil
                    terminate.cancel(); forceStop.cancel()
                    try? output.fileHandleForWriting.close()
                    queue.async { source.cancel(); continuation.resume(throwing: error) }
                }
            }
        }.value
    }
}

private final class RenewalOutputCapture: @unchecked Sendable {
    private var data = Data()
    var text: String { String(decoding: data, as: UTF8.self) }
    func drain(_ fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                if data.count > 65536 { data.removeFirst(data.count - 65536) }
            } else if count < 0 && errno == EINTR { continue }
            else { return }
        }
    }
}
