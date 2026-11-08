import Foundation
import CryptoKit
import SwitcherCore

struct LocalAccountObservation: Equatable {
    let desktopAccountID: String?
    let fingerprint: String
    var cliIdentityFingerprint: String? = nil

    static func read(desktop: URL, cli: URL, profile: String, scope: DesktopProtectionScope) -> Self {
        // Select auth metadata only: quota-cache or unrelated preference writes are not a login change.
        let config = (try? Data(contentsOf: desktop)).flatMap { try? CLIJSON.object($0) }
        let document = (try? Data(contentsOf: cli)).flatMap { try? CLIJSON.object($0) }
        let account = config?["lastKnownAccountUuid"] as? String
        let fields: [String: Any] = ["profile": profile, "scope": scope.rawValue,
            "desktopAccount": account ?? "", "desktopToken": config?["oauth:tokenCacheV2"] as? String ?? "",
            "cliIdentity": document?["oauthAccount"] ?? NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)) ?? Data()
        let cliData = (try? JSONSerialization.data(withJSONObject: ["identity": document?["oauthAccount"] ?? NSNull()], options: .sortedKeys)) ?? Data()
        return Self(desktopAccountID: account, fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    cliIdentityFingerprint: SHA256.hash(data: cliData).map { String(format: "%02x", $0) }.joined())
    }
}

@MainActor extension Store {
    func applyLocalAccountObservation(_ observation: LocalAccountObservation) -> Bool {
        let changed = localAccountObservation != nil && localAccountObservation != observation
        let cliChanged = localAccountObservation != nil && localAccountObservation?.cliIdentityFingerprint != observation.cliIdentityFingerprint
        localAccountObservation = observation
        if changed { usageRefreshPolicy.credentialsChanged(profile: current); usageCatchUpPending = true }
        if cliChanged {
            invalidateCLIStatus()
            cliConnection.defaultLoginDidChange()
        }
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
            cliConnection.contextDidChange()
        }
        return changed
    }

    func observeAccountMetadata(importUsage: Bool = true) async -> Bool {
        reloadList(); protection.refreshScope()
        let observation = LocalAccountObservation.read(desktop: liveDir.appendingPathComponent("config.json"),
                                                       cli: claudeJSON, profile: current, scope: protection.desktopScope)
        let changed = applyLocalAccountObservation(observation)
        await refreshCLI(verify: false)
        cliConnection.contextDidChange()
        cliConnection.refreshLocalRecord()
        // A running official CLI may have written a new sample between network polls.
        if importUsage, let sample = try? await readSelectedCLIUsageCache(),
           sample.fetchedAt <= Date(),
           profiles.contains(where: { $0.snapshot?.identity.samePrincipal(as: sample.identity) == true
               && ($0.snapshot?.fetchedAt ?? .distantPast) < sample.fetchedAt }) {
            applyOfficialUsage(sample)
        }
        onChange?()
        return changed
    }

    func automaticRefresh() async {
        guard !isDemo, !updating, busy == nil, !refreshing, !cliStatusRefreshing, !automaticRefreshInProgress, !statusRefreshInProgress else { return }
        automaticRefreshInProgress = true
        defer { automaticRefreshInProgress = false }
        // Metadata observation is cheap. Only the active subscription desktop
        // gets a bounded, silent usage request when the sample is due.
        _ = await observeAccountMetadata()
        guard protection.desktopScope == .subscription, claudeRunning || panelIsVisible(),
              protection.enabled, let profile = active, profile.signedIn || localAccountObservation?.desktopAccountID != nil else { return }
        let name = current, now = Date()
        // An older application's fresh quota sample may carry no identity.
        let sampled = profile.snapshot?.identity.isComplete == true ? profile.snapshot?.fetchedAt : nil
        guard usageRefreshPolicy.shouldRequest(profile: name, sampledAt: sampled, resetsAt: [],
                                               active: true, trigger: .periodic, now: now),
              usageRefreshPolicy.permitsExplicitRequest(profile: name, now: now) else { return }
        usageRefreshPolicy.began(profile: name, now: now)
        do {
            _ = try await refreshCurrentDesktopUsage(allowInteraction: false)
            usageNotice = nil
            linkedUsageDetails = nil
        } catch {
            guard current == name else { return }
            usageRefreshPolicy.failed(profile: name, now: Date(), retryAfter: (error as? DesktopUsageHTTPFailure)?.retryAfter)
        }
    }
}
