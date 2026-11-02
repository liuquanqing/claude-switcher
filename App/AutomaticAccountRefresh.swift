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

    func observeAccountMetadata() async -> Bool {
        reloadList(); protection.refreshScope()
        let observation = LocalAccountObservation.read(desktop: liveDir.appendingPathComponent("config.json"),
                                                       cli: claudeJSON, profile: current, scope: protection.desktopScope)
        let changed = applyLocalAccountObservation(observation)
        await refreshCLI(verify: false)
        // A running official CLI may have written a new sample between network polls.
        if let data = try? Data(contentsOf: claudeJSON), let sample = try? OfficialCLIUsageCache.read(data),
           profiles.contains(where: { $0.snapshot?.identity.samePrincipal(as: sample.identity) == true
               && ($0.snapshot?.fetchedAt ?? .distantPast) < sample.fetchedAt }) {
            applyOfficialUsage(sample)
        }
        onChange?()
        return changed
    }

    func automaticRefresh(trigger: UsageRefreshPolicy.Trigger = .periodic, now: Date = Date()) async {
        guard !isDemo, busy == nil, !refreshing, !cliStatusRefreshing, !automaticRefreshInProgress, !statusRefreshInProgress else { return }
        automaticRefreshInProgress = true
        defer { automaticRefreshInProgress = false }
        let changed = await observeAccountMetadata()
        await recoverCurrentCLI()
        let name = current
        let snapshot = active?.snapshot
        let resetDates = [snapshot?.session?.resetsAt, snapshot?.weekly?.resetsAt].compactMap { $0 }
        guard usageRefreshPolicy.shouldRequest(profile: name, sampledAt: snapshot?.fetchedAt, resetsAt: resetDates,
            active: claudeRunning || panelIsVisible() || trigger == .panel,
            trigger: changed || usageCatchUpPending ? .identityChanged : trigger, now: now) else { return }
        guard busy == nil, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        usageRefreshPolicy.began(profile: name, now: now)
        do { try await refreshQuietUsage(); usageCatchUpPending = false }
        catch {
            usageRefreshPolicy.failed(profile: name, now: Date(), retryAfter: (error as? UsageHTTPFailure)?.retryAfter)
            usageNotice = error.localizedDescription
            if let index = profiles.firstIndex(where: { $0.name == name }), profiles[index].snapshot != nil {
                profiles[index].usageState = .cached
            }
        }
        // The first desktop observation may establish a previously missing identity.
        await refreshCLI(verify: false)
        onChange?()
    }
}
