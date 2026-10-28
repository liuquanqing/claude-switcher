import Foundation
import SwitcherCore

enum CLIStatusReader {
    static func read(home: URL) async throws -> CLIReportedStatus {
        try await Task.detached(priority: .utility) {
            let paths = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
            guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw SafetyError("未找到本机 Claude CLI，未修改登录。")
            }
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = ["auth", "status"]
            process.currentDirectoryURL = home
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            process.environment = environment
            try process.run()
            // Stop only this newly spawned status query if it cannot finish; existing
            // terminal sessions and Claude Desktop are never addressed here.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationReason == .exit, [0, 1].contains(process.terminationStatus) else {
                throw SafetyError("CLI 状态读取超时或未完成，未修改登录。")
            }
            let report = try CLIReportedStatus(data: data)
            guard (process.terminationStatus == 0) == report.loggedIn else { throw SafetyError("CLI 退出状态与登录报告不一致。") }
            return report
        }.value
    }
}
