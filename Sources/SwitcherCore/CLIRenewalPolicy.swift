import Foundation

/// One native attempt per saved-login generation. Temporary failures retry on a
/// bounded interval; a confirmed expired login is not retried every UI tick.
public struct CLIRenewalPolicy {
    private var version: String?
    private var nextAttempt: Date?
    private var paused = false
    public init() {}
    public mutating func begin(version: String, now: Date, manual: Bool) -> Bool {
        if self.version != version { self.version = version; paused = false; nextAttempt = nil }
        guard manual || !paused && (nextAttempt == nil || now >= nextAttempt!) else { return false }
        nextAttempt = now.addingTimeInterval(300)
        return true
    }
    public mutating func finish(_ result: CLICurrentRecoveryOutcome, version: String? = nil, now: Date) {
        if let version { self.version = version }
        switch result {
        case .needsLogin, .authorizationRequired, .unsupported, .backupPending: paused = true
        case .contextChanged: self.version = nil; nextAttempt = nil; paused = false
        case .notNeeded: nextAttempt = now.addingTimeInterval(60)
        default: nextAttempt = now.addingTimeInterval(300)
        }
    }
}
