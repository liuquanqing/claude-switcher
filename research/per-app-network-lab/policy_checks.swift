import Foundation

@main struct PolicyChecks {
    static func main() throws {
        let good = Permit(sampledAt: 10, expiresAt: 12, context: "route-2", country: "SG", tunnelReady: true)
        let scenarios: [(String, Permit?, Double, String, Verdict)] = [
            ("no-evidence", nil, 11, "route-2", .drop),
            ("fresh-SG", good, 11, "route-2", .allow),
            ("expiry-boundary", good, 12, "route-2", .drop),
            ("expired", good, 13, "route-2", .drop),
            ("future-sample", good, 9, "route-2", .drop),
            ("context-changed", good, 11, "route-3", .drop),
            ("JP", Permit(sampledAt: 10, expiresAt: 12, context: "route-2", country: "JP", tunnelReady: true), 11, "route-2", .drop),
            ("unknown-country", Permit(sampledAt: 10, expiresAt: 12, context: "route-2", country: nil, tunnelReady: true), 11, "route-2", .drop),
            ("tunnel-down", Permit(sampledAt: 10, expiresAt: 12, context: "route-2", country: "SG", tunnelReady: false), 11, "route-2", .drop)
        ]
        var count = 0
        for target in ["fictional-desktop", "fictional-existing-terminal-cli", "fictional-helper", "fictional-delegated-flow"] {
            for (name, permit, now, context, expected) in scenarios {
                precondition(SelectivePolicy.verdict(owner: .protectedIdentity(target), permit: permit, now: now,
                    context: context, targetCountry: "SG") == expected, "\(target):\(name)")
                count += 1
            }
        }
        for (_, permit, now, context, _) in scenarios {
            precondition(SelectivePolicy.verdict(owner: .verifiedOther, permit: permit, now: now,
                context: context, targetCountry: "SG") == .allow)
            precondition(SelectivePolicy.verdict(owner: .unresolved, permit: permit, now: now,
                context: context, targetCountry: "SG") == .unresolved)
            count += 2
        }
        // New and existing flow *decisions* use the same contract. These are not
        // evidence of OS revocation, DNS coverage, actual flow ownership or crash behavior.
        let result: [String: Any] = ["layer": "pure-policy-fixtures", "checks": count, "passed": true,
            "OSFilterInstalled": false, "actualFlowAttribution": "NOT_RUN", "productionReady": false]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
