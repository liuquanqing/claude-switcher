import Foundation
import Darwin

public struct AppUpdateInstallPlan: Codable, Equatable, Sendable {
    public let id: UUID
    public let application: URL
    public let stagedApplication: URL
    public let oldBuild: String
    public let newBuild: String
    public let release: String
    public init(id: UUID = UUID(), application: URL, stagedApplication: URL, oldBuild: String, newBuild: String, release: String) {
        self.id = id; self.application = application; self.stagedApplication = stagedApplication
        self.oldBuild = oldBuild; self.newBuild = newBuild; self.release = release
    }
    public func validatePaths() throws {
        func numericBuild(_ value: String) -> Bool {
            !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        }
        guard application.isFileURL, stagedApplication.isFileURL,
              application.pathExtension == "app", application != stagedApplication,
              application.deletingLastPathComponent().standardizedFileURL == stagedApplication.deletingLastPathComponent().standardizedFileURL,
              stagedApplication.lastPathComponent == ".claude-switcher-update-\(id.uuidString).app",
              numericBuild(oldBuild), numericBuild(newBuild),
              newBuild.compare(oldBuild, options: .numeric) == .orderedDescending else {
            throw SafetyError("更新目标无法确认。")
        }
        for path in [application, stagedApplication] {
            let attributes = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
                throw SafetyError("更新目标不是普通应用目录。")
            }
        }
    }
    public static func exchange(_ a: URL, _ b: URL) throws {
        guard renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public enum AppUpdateInstallState: String, Codable, Sendable {
    case prepared, waitingForExit, replacing, launching, complete, failed, rolledBack, recoveryRequired
}
public struct AppUpdateInstallResult: Codable, Sendable {
    public let id: UUID
    public let state: AppUpdateInstallState
    public let message: String?
    public init(id: UUID, state: AppUpdateInstallState, message: String? = nil) {
        self.id = id; self.state = state; self.message = message
    }
}

/// Injected operations keep all unit tests inside temporary, fictional apps.
@MainActor public struct AppUpdateInstallOperations {
    public let validate: () throws -> Void
    public let isRunning: () -> Bool
    public let exchange: () throws -> Void
    public let launch: () async throws -> Void
    public let acknowledged: () -> Bool
    public let quitNewApplication: () async throws -> Void
    public let record: (AppUpdateInstallResult) throws -> Void
    public let now: () -> Date
    public let wait: () async throws -> Void
    public init(validate: @escaping () throws -> Void, isRunning: @escaping () -> Bool,
                exchange: @escaping () throws -> Void, launch: @escaping () async throws -> Void,
                acknowledged: @escaping () -> Bool, quitNewApplication: @escaping () async throws -> Void,
                record: @escaping (AppUpdateInstallResult) throws -> Void,
                now: @escaping () -> Date = Date.init,
                wait: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }) {
        self.validate = validate; self.isRunning = isRunning; self.exchange = exchange; self.launch = launch
        self.acknowledged = acknowledged; self.quitNewApplication = quitNewApplication; self.record = record
        self.now = now; self.wait = wait
    }
}

@MainActor public enum AppUpdateInstall {
    public static func run(plan: AppUpdateInstallPlan, operations io: AppUpdateInstallOperations,
                           exitTimeout: TimeInterval = 30, launchTimeout: TimeInterval = 30,
                           resumeAfterSwap: Bool = false) async -> AppUpdateInstallResult {
        func result(_ state: AppUpdateInstallState, _ message: String? = nil) -> AppUpdateInstallResult {
            AppUpdateInstallResult(id: plan.id, state: state, message: message)
        }
        var swapped = resumeAfterSwap
        var validated = false
        do {
            try io.validate()
            validated = true
            if !swapped {
                try io.record(result(.waitingForExit))
                let deadline = io.now().addingTimeInterval(exitTimeout)
                while io.isRunning() {
                    guard io.now() < deadline else { throw SafetyError("切换器尚未退出，原版本已保留。") }
                    try await io.wait()
                }
                try io.validate()
                try io.record(result(.replacing))
                try io.exchange(); swapped = true
            }
            try io.record(result(.launching))
            try await io.launch()
            let launchDeadline = io.now().addingTimeInterval(launchTimeout)
            while !io.acknowledged() {
                guard io.now() < launchDeadline else { throw SafetyError("新版未完成启动确认。") }
                try await io.wait()
            }
            let done = result(.complete)
            try? io.record(done)
            return done
        } catch {
            let failure = error.localizedDescription
            if swapped && validated {
                do {
                    try await io.quitNewApplication()
                    guard !io.isRunning() else { throw SafetyError("新版尚未退出，已保留两个版本以便恢复。") }
                    try io.exchange()
                    try await io.launch()
                    let restored = result(.rolledBack, failure)
                    try io.record(restored)
                    return restored
                } catch {
                    let pending = result(.recoveryRequired, error.localizedDescription)
                    try? io.record(pending)
                    return pending
                }
            }
            if validated && !io.isRunning() { try? await io.launch() }
            let failed = result(.failed, failure)
            try? io.record(failed)
            return failed
        }
    }
}
