import Foundation

/// Request cadence is separate from sample age. Failed reads never make data fresh.
public struct UsageRefreshPolicy {
    public enum Trigger { case periodic, panel, wake, identityChanged }
    private struct Attempt { var at: Date; var retryAfter: Date? }
    private var attempts: [String: Attempt] = [:]
    public init() {}

    public func shouldRequest(profile: String, sampledAt: Date?, resetsAt: [Date],
                              active: Bool, trigger: Trigger, now: Date) -> Bool {
        if let attempt = attempts[profile] {
            if let retry = attempt.retryAfter, now < retry { return false }
            if now.timeIntervalSince(attempt.at) < 60 { return false }
        }
        if trigger == .identityChanged { return true }
        guard let sampledAt else { return true }
        // An expired window needs a real sample, not a locally invented reset.
        if resetsAt.contains(where: { $0 > sampledAt && $0 <= now }) { return true }
        return now.timeIntervalSince(sampledAt) >= (active ? 300 : 900)
    }

    public mutating func began(profile: String, now: Date) {
        attempts[profile] = Attempt(at: now, retryAfter: nil)
    }
    public mutating func failed(profile: String, now: Date, retryAfter: Date? = nil) {
        // Ordinary failures back off for five minutes; honor the server's longer delay.
        attempts[profile] = Attempt(at: now, retryAfter: max(now.addingTimeInterval(300), retryAfter ?? now))
    }
}
