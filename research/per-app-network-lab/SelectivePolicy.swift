import Foundation

// Research contract only. This does not install a filter, obtain real flow
// attribution, or decide what macOS does when a provider stops running.
enum FlowOwner: Equatable {
    case protectedIdentity(String)
    case verifiedOther
    case unresolved
}
enum Verdict: Equatable { case allow, drop, unresolved }
struct Permit {
    let sampledAt: Double
    let expiresAt: Double
    let context: String
    let country: String?
    let tunnelReady: Bool
}
enum SelectivePolicy {
    static func verdict(owner: FlowOwner, permit: Permit?, now: Double,
                        context: String, targetCountry: String) -> Verdict {
        switch owner {
        case .verifiedOther: return .allow
        // Resolving this requires actual OS flow evidence. Turning an unknown
        // into allow leaks targets; turning it into drop can break other apps.
        // Neither constitutes a passed per-app deployment gate.
        case .unresolved: return .unresolved
        case .protectedIdentity:
            guard now.isFinite, let permit, permit.sampledAt.isFinite,
                  permit.expiresAt.isFinite,
                  permit.sampledAt <= now, now < permit.expiresAt,
                  permit.expiresAt > permit.sampledAt,
                  permit.context == context, permit.tunnelReady,
                  permit.country == targetCountry else { return .drop }
            return .allow
        }
    }
}
