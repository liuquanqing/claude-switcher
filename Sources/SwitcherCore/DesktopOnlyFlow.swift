import Foundation

public struct DesktopOnlyFailure: Error, LocalizedError, Sendable {
    /// false: before move; nil: move failed and its outcome needs inspection; true: move completed.
    public let directoryChanged: Bool?
    public let message: String
    public var errorDescription: String? { message }
}

/// Explicit user-selected Desktop exception. There is no CLI storage dependency.
@MainActor public enum DesktopOnlyFlow {
    public static func run(transaction: ProfileTransaction, from source: String, to target: String,
                           current: () throws -> String, subscriptionMode: () throws -> Bool,
                           quit: () async throws -> Bool, check: () async -> SafetyDecision,
                           launch: () async throws -> Void) async throws {
        var changed: Bool? = false
        do {
            try await LaunchGate.run(check: check, prepare: {
                guard try current() == source else { throw SafetyError("当前档案已变化，请重新选择。") }
                try transaction.validate(from: source, to: target)
                guard try subscriptionMode() else { throw SafetyError("桌面为 API 或模式未确认，请回原工具管理。") }
                guard try await quit() else { throw SafetyError("Claude 未退出，目录未移动。") }
                guard try current() == source, try subscriptionMode() else { throw SafetyError("退出后档案或模式已变化，未移动目录。") }
                changed = nil
                try transaction.switchProfile(from: source, to: target)
                changed = true
            }, launch: launch)
        } catch { throw DesktopOnlyFailure(directoryChanged: changed, message: error.localizedDescription) }
    }
}
