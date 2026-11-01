import Foundation
import CoreFoundation

public struct SubscriptionUsageSample: Sendable {
    public let session: OfficialUsageWindow?
    public let weekly: OfficialUsageWindow?
    public let weeklyOpus: OfficialUsageWindow?

    public static func read(_ data: Data) throws -> Self {
        let object = try CLIJSON.object(data)
        func window(_ key: String) throws -> OfficialUsageWindow? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            guard let row = value as? [String: Any], let used = row["utilization"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite,
                  (0...100).contains(used.doubleValue) else {
                throw SafetyError("订阅额度格式无法确认，保留原数据。")
            }
            var reset: Date?
            if let raw = row["resets_at"], !(raw is NSNull) {
                guard let text = raw as? String else { throw SafetyError("订阅重置时间格式无法确认。") }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: text)
                if reset == nil { formatter.formatOptions = [.withInternetDateTime]; reset = formatter.date(from: text) }
                guard reset != nil else { throw SafetyError("订阅重置时间格式无法确认。") }
            }
            return OfficialUsageWindow(used: used.doubleValue, resetsAt: reset)
        }
        let session = try window("five_hour"), weekly = try window("seven_day")
        guard session != nil || weekly != nil else { throw SafetyError("订阅暂无可读额度，保留原数据。") }
        return Self(session: session, weekly: weekly, weeklyOpus: try window("seven_day_opus"))
    }
}
