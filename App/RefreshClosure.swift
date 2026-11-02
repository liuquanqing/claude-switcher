import Foundation
import SwitcherCore

/// All dependencies are required for fictional runs. The same orchestration is
/// used by the actual footer, linked-switch completion and injected tests.
@MainActor struct StatusRefreshOperations {
    let recover: () async -> CLICurrentRecoveryOutcome
    let gate: () async -> Bool
    let bootstrap: (Bool) async throws -> Void
    let readCache: () async throws -> OfficialCLIUsageCache?
    let fetchFresh: () async throws -> Void
}

@MainActor extension Store {
    func refreshAllStatuses(operations supplied: StatusRefreshOperations? = nil, now: Date = Date(), clock suppliedClock: (() -> Date)? = nil) async {
        guard busy == nil, !refreshing, !cliStatusRefreshing,
              !statusRefreshInProgress, !automaticRefreshInProgress else { return }
        if isDemo && supplied == nil { await verifyDefaultCLI(); return }
        statusRefreshInProgress = true
        lastRefreshDiagnostics = RefreshDiagnostics()
        defer {
            statusRefreshInProgress = false
            lastRefreshDiagnostics?.completedAt = Date()
            if lastRefreshDiagnostics?.outcome == "pending" {lastRefreshDiagnostics?.outcome = "notCompleted"}
            if !isDemo { lastRefreshDiagnostics?.save() }
            onChange?()
        }
        let name = current, scope = protection.desktopScope
        let clock: () -> Date = suppliedClock ?? (supplied == nil ? Date.init : {now})
        guard usageRefreshPolicy.permitsExplicitRequest(profile: name, now: now) else {
            lastRefreshDiagnostics?.outcome = "rateLimited"
            usageNotice = "额度查询受限，将按服务器指定时间重试。"; return
        }
        let operations = supplied ?? StatusRefreshOperations(
            recover: { await self.recoverCurrentCLI(manual: true, requestNativeCheck: self.cliRecoveryNeedsAttention) },
            gate: { await self.protection.preflight(target: .subscriptionUsage).allowed },
            bootstrap: { interaction in
                if self.needsActiveAccountBootstrap { _ = try await self.profileDescriptor(name, allowInteraction: interaction) }
            },
            readCache: { try await OfficialCLIUsageReader.read(home: FileManager.default.homeDirectoryForCurrentUser, manual: false) },
            fetchFresh: { try await self.refreshQuietUsage() })
        let recovery = await operations.recover()
        lastRefreshDiagnostics?.recoveryOutcome = String(describing: recovery)
        guard current == name, protection.desktopScope == scope, recovery != .contextChanged else {
            lastRefreshDiagnostics?.outcome = "contextChanged";return
        }
        // A denied/cancelled authorization ends this action. Never chase it with
        // another credential object or native helper in the same click.
        if recovery == .authorizationRequired || recovery == .unsupported {
            lastRefreshDiagnostics?.outcome = String(describing: recovery);return
        }
        guard await operations.gate(), current == name, protection.desktopScope == scope else {
            lastRefreshDiagnostics?.outcome = "networkHold"
            usageNotice = "网络检查未通过，保留原额度。"; return
        }
        do {
            try await operations.bootstrap(recovery == .notNeeded || recovery == .renewed)
            guard current == name, protection.desktopScope == scope else { return }
            if let sample = try? await operations.readCache(),
               sample.identity.samePrincipal(as: active?.snapshot?.identity ?? CLIIdentity(accountID: nil, organizationID: nil, email: nil)),
               sample.fetchedAt >= (active?.snapshot?.fetchedAt ?? .distantPast),
               (0..<30).contains(clock().timeIntervalSince(sample.fetchedAt)) {
                applyOfficialUsage(sample);usageCatchUpPending = false;usageNotice = nil
                lastRefreshDiagnostics?.quotaCacheAdopted = true;lastRefreshDiagnostics?.outcome = "completed";return
            }
            // Recovery is about credentials; cache freshness is a separate result.
            // The fallback is one gated read, never a second token rotation.
            refreshing = true
            defer { refreshing = false }
            usageRefreshPolicy.began(profile: name, now: clock())
            lastRefreshDiagnostics?.freshQuotaRequests += 1
            try await operations.fetchFresh()
            if current == name, protection.desktopScope == scope { usageCatchUpPending = false;usageNotice = nil;lastRefreshDiagnostics?.outcome = "completed" }
        } catch {
            guard current == name, protection.desktopScope == scope else { return }
            lastRefreshDiagnostics?.outcome = "failed"
            usageRefreshPolicy.failed(profile: name, now: clock(), retryAfter: (error as? UsageHTTPFailure)?.retryAfter)
            usageNotice = error.localizedDescription
        }
        protection.refreshStatus()
    }
}
