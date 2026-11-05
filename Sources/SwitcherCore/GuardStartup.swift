import Foundation

public enum GuardStartup {
    public static func accepts(_ receipt: GuardReceipt?, config: SafetyConfig, startedAt: Date, now: Date) -> Bool {
        guard let receipt else { return false }
        return receipt.checkedAt >= startedAt && receipt.isFresh(for: config, now: now)
            && receipt.supportsUnchangedModeMarker == true
    }
    public static func wait(config: SafetyConfig, startedAt: Date, timeout: TimeInterval = 25,
                            receipt: () -> GuardReceipt?, stillEnabled: () -> Bool,
                            now: () -> Date = Date.init,
                            sleep: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }) async throws {
        let deadline = now().addingTimeInterval(timeout)
        while now() <= deadline {
            guard stillEnabled() else { throw SafetyError("保护设置已变化，已停止等待旧操作。") }
            if accepts(receipt(), config: config, startedAt: startedAt, now: now()) { return }
            try await sleep()
        }
        throw SafetyError("尚未收到本次守卫检查结果，请重试保护。")
    }
}
