import Foundation
import SwitcherCore

@MainActor struct StatusRefreshOperations {
    let observe: () async -> Void
    let readCache: () async throws -> OfficialCLIUsageCache?
}

@MainActor extension Store {
    /// Explicit footer refresh imports existing samples, then queries prepared
    /// account bindings through an isolated, proxy-constrained official CLI.
    func refreshAllStatuses(operations supplied: StatusRefreshOperations? = nil) async {
        guard !updating, busy == nil, !refreshing, !cliStatusRefreshing,
              !statusRefreshInProgress, !automaticRefreshInProgress else { return }
        if isDemo && supplied == nil { await verifyDefaultCLI(); return }
        statusRefreshInProgress = true
        lastRefreshDiagnostics = RefreshDiagnostics()
        defer {
            statusRefreshInProgress = false
            lastRefreshDiagnostics?.completedAt = Date()
            if !isDemo { lastRefreshDiagnostics?.save() }
            onChange?()
        }

        let name = current, scope = protection.desktopScope
        let operations = supplied ?? StatusRefreshOperations(
            observe: { _ = await self.observeAccountMetadata(importUsage: false) },
            readCache: { try await self.readSelectedCLIUsageCache() })
        await operations.observe()
        do {
            let sample = try await operations.readCache()
            guard current == name, protection.desktopScope == scope else {
                lastRefreshDiagnostics?.outcome = "contextChanged"; return
            }
            usageNotice = nil
            applyOfficialUsage(sample.flatMap { $0.fetchedAt <= Date() ? $0 : nil })
            lastRefreshDiagnostics?.quotaCacheAdopted = usageNotice == nil
            lastRefreshDiagnostics?.outcome = usageNotice == nil ? "completed" : "cacheUnavailable"
        } catch {
            lastRefreshDiagnostics?.outcome = "cacheUnavailable"
            usageNotice = error.localizedDescription
        }
        if supplied == nil && !isDemo {
            await refreshLinkedAccountUsage()
            lastRefreshDiagnostics?.outcome = usageNotice == nil ? "completed" : "queryIncomplete"
        }
        protection.refreshStatus()
    }
}
