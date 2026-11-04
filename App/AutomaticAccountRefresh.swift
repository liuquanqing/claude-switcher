import Foundation
import CryptoKit
import SwitcherCore

struct LocalAccountObservation: Equatable {
    let desktopAccountID: String?
    let fingerprint: String

    static func read(desktop: URL, cli: URL, profile: String, scope: DesktopProtectionScope) -> Self {
        // Select auth metadata only: quota-cache or unrelated preference writes are not a login change.
        let config = (try? Data(contentsOf: desktop)).flatMap { try? CLIJSON.object($0) }
        let document = (try? Data(contentsOf: cli)).flatMap { try? CLIJSON.object($0) }
        let account = config?["lastKnownAccountUuid"] as? String
        let fields: [String: Any] = ["profile": profile, "scope": scope.rawValue,
            "desktopAccount": account ?? "", "desktopToken": config?["oauth:tokenCacheV2"] as? String ?? "",
            "cliIdentity": document?["oauthAccount"] ?? NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)) ?? Data()
        return Self(desktopAccountID: account, fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

@MainActor extension Store {
    func applyLocalAccountObservation(_ observation: LocalAccountObservation) -> Bool {
        let changed = localAccountObservation != nil && localAccountObservation != observation
        localAccountObservation = observation
        if changed { usageRefreshPolicy.credentialsChanged(profile: current); usageCatchUpPending = true }
        if protection.desktopScope == .subscription,
           let actual = observation.desktopAccountID, let saved = active?.snapshot?.identity.accountID,
           CLIReportedStatus.sameAccountRecord(CLIIdentity(accountID: actual, organizationID: nil, email: nil),
                                               CLIIdentity(accountID: saved, organizationID: nil, email: nil)) == false,
           let index = profiles.firstIndex(where: { $0.name == current }) {
            // An external login can change in place, without the .current marker moving.
            // Keep the disk's historical sample; stop presenting it as the new active identity.
            profiles[index].snapshot = nil; profiles[index].usageState = .notRequested
            resetCurrentCLIRecoveryObservation()
            invalidateCLIStatus()
        }
        return changed
    }

    func observeAccountMetadata(importUsage: Bool = true) async -> Bool {
        reloadList(); protection.refreshScope()
        let observation = LocalAccountObservation.read(desktop: liveDir.appendingPathComponent("config.json"),
                                                       cli: claudeJSON, profile: current, scope: protection.desktopScope)
        let changed = applyLocalAccountObservation(observation)
        await refreshCLI(verify: false)
        // A running official CLI may have written a new sample between network polls.
        if importUsage, let data = try? Data(contentsOf: claudeJSON), let sample = try? OfficialCLIUsageCache.read(data),
           sample.fetchedAt <= Date(),
           profiles.contains(where: { $0.snapshot?.identity.samePrincipal(as: sample.identity) == true
               && ($0.snapshot?.fetchedAt ?? .distantPast) < sample.fetchedAt }) {
            applyOfficialUsage(sample)
        }
        onChange?()
        return changed
    }

    func automaticRefresh() async {
        guard !isDemo, busy == nil, !refreshing, !cliStatusRefreshing, !automaticRefreshInProgress, !statusRefreshInProgress else { return }
        automaticRefreshInProgress = true
        defer { automaticRefreshInProgress = false }
        // Startup, wake and timer observe only metadata and an existing quota
        // sample. They never launch Claude Code, touch Keychain or recover a login.
        _ = await observeAccountMetadata()
    }
}
