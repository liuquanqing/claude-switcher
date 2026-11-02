import Foundation

/// Request cadence is separate from sample age. Failed reads never make data fresh.
public struct UsageRefreshPolicy {
    public enum Trigger { case periodic, panel, wake, identityChanged }
    private struct Attempt { var at: Date; var retryAfter: Date?; var serverDeadline: Date? = nil }
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

    /// Login generations can repair an ordinary authentication failure, never a
    /// server-imposed limit. Explicit refresh observes the same server deadline.
    public func permitsExplicitRequest(profile: String, now: Date) -> Bool {
        attempts[profile]?.serverDeadline.map { now >= $0 } ?? true
    }
    public mutating func credentialsChanged(profile: String) {
        guard let old = attempts[profile] else { return }
        if let deadline = old.serverDeadline {
            attempts[profile] = Attempt(at: .distantPast, retryAfter: deadline, serverDeadline: deadline)
        } else { attempts.removeValue(forKey: profile) }
    }
    public mutating func began(profile: String, now: Date) {
        let deadline = attempts[profile]?.serverDeadline
        attempts[profile] = Attempt(at: now, retryAfter: deadline, serverDeadline: deadline)
    }
    public mutating func failed(profile: String, now: Date, retryAfter: Date? = nil) {
        // Ordinary failures back off for five minutes; honor the server's longer delay.
        attempts[profile] = Attempt(at: now, retryAfter: max(now.addingTimeInterval(300), retryAfter ?? now),
                                    serverDeadline: retryAfter ?? attempts[profile]?.serverDeadline)
    }
}
