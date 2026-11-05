import Foundation
import SwitcherCore

enum CLIStatusReader {
    static func read(home: URL, configurationDirectory: URL? = nil, timeoutSeconds: TimeInterval = 8, graceSeconds: TimeInterval = 2) async throws -> CLIReportedStatus {
        try await Task.detached(priority: .utility) {
            let paths = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
            guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw SafetyError("未找到本机 Claude CLI，未修改登录。")
            }
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            if let configurationDirectory {
                environment = CLITerminalLaunch.environment(home: home, directory: configurationDirectory, inherited: environment)
            }
            environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            environment["DISABLE_AUTOUPDATER"] = "1"
            let result = try await BoundedCLICommand.run(home: home, executable: executable,
                arguments: ["auth", "status"], inherited: environment, timeoutSeconds: timeoutSeconds,
                graceSeconds: graceSeconds, combineStderr: false)
            guard !result.timedOut, [0, 1].contains(result.status) else {
                throw SafetyError("CLI 状态读取超时或未完成，未修改登录。")
            }
            let data = Data(result.text.utf8)
            let report = try CLIReportedStatus(data: data)
            guard (result.status == 0) == report.loggedIn else { throw SafetyError("CLI 退出状态与登录报告不一致。") }
            return report
        }.value
    }
}
