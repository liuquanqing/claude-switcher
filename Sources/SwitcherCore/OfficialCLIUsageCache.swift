import Foundation
import CoreFoundation

public struct OfficialUsageWindow: Sendable, Equatable {
    public let used: Double
    public let resetsAt: Date?
}

/// A native CLI reading. Cache reads preserve its timestamp; native command
/// output is dated only when a fresh, recognized /usage response is received.
public struct OfficialCLIUsageCache: Sendable, Equatable {
    public let identity: CLIIdentity
    public let fetchedAt: Date
    public let session: OfficialUsageWindow?
    public let weekly: OfficialUsageWindow?
    public let weeklyOpus: OfficialUsageWindow?

    public static func identity(in document: Data) throws -> CLIIdentity? {
        try CLIIdentity.metadata(CLIJSON.field(document, key: "oauthAccount"))
    }

    public static func read(_ document: Data) throws -> Self? {
        let object = try CLIJSON.object(document)
        guard let identity = try identity(in: document), identity.isComplete else { return nil }
        guard let raw = object["cachedUsageUtilization"] else { return nil }
        guard let cache = raw as? [String: Any], let account = cache["accountUuid"] as? String,
              CLIReportedStatus.sameAccountRecord(identity, CLIIdentity(accountID: account, organizationID: nil, email: nil)) == true,
              let sampled = cache["fetchedAtMs"] as? NSNumber,
              CFGetTypeID(sampled) != CFBooleanGetTypeID(), sampled.doubleValue.isFinite, sampled.doubleValue > 0,
              let utilization = cache["utilization"] as? [String: Any] else {
            throw SafetyError("官方 CLI 用量缓存的账号或采样时间无法确认，保留原数据。")
        }
        func window(_ key: String) throws -> OfficialUsageWindow? {
            guard let value = utilization[key], !(value is NSNull) else { return nil }
            guard let row = value as? [String: Any], let used = row["utilization"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite,
                  (0...100).contains(used.doubleValue) else {
                throw SafetyError("官方 CLI 用量缓存格式无法确认，保留原数据。")
            }
            var deadline: Date?
            if let raw = row["resets_at"], !(raw is NSNull) {
                guard let text = raw as? String else { throw SafetyError("官方 CLI 重置时间格式无法确认。") }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                deadline = formatter.date(from: text)
                if deadline == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    deadline = formatter.date(from: text)
                }
                guard deadline != nil else { throw SafetyError("官方 CLI 重置时间格式无法确认。") }
            }
            return OfficialUsageWindow(used: used.doubleValue, resetsAt: deadline)
        }
        let session = try window("five_hour"), weekly = try window("seven_day")
        guard session != nil || weekly != nil else { return nil }
        return Self(identity: identity, fetchedAt: Date(timeIntervalSince1970: sampled.doubleValue / 1000),
                    session: session, weekly: weekly, weeklyOpus: try window("seven_day_opus"))
    }
}
