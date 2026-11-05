import Foundation
import SwitcherCore

@MainActor struct StatusRefreshOperations {
    let observe: () async -> Void
    let readCache: () async throws -> OfficialCLIUsageCache?
}

@MainActor extension Store {
    /// Footer refresh consumes the CLI's existing sample. It never starts
    /// a native CLI process, requests credentials or attempts login repair.
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
            readCache: { try await OfficialCLIUsageReader.read(home: FileManager.default.homeDirectoryForCurrentUser, manual: false) })
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
        protection.refreshStatus()
    }
}
