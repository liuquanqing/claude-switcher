import Foundation
import SwitcherCore

@MainActor struct StatusRefreshOperations {
    let observe: () async -> Void
    let readCache: () async throws -> OfficialCLIUsageCache?
}

@MainActor extension Store {
    /// Explicit refresh uses the current subscription desktop's own login.
    /// Other saved profiles still use their associated CLI directories.
    func refreshAllStatuses(operations supplied: StatusRefreshOperations? = nil) async {
        guard !updating, busy == nil, !refreshing, !statusRefreshInProgress else { return }
        if isDemo && supplied == nil { await verifyDefaultCLI(); return }
        statusRefreshInProgress = true
        lastRefreshDiagnostics = RefreshDiagnostics()
        defer {
            statusRefreshInProgress = false
            lastRefreshDiagnostics?.completedAt = Date()
            if !isDemo { lastRefreshDiagnostics?.save() }
            onChange?()
        }
        // A click during the timer's read waits for that read instead of
        // silently doing nothing or issuing a second concurrent request.
        let waitUntil = Date().addingTimeInterval(30)
        while automaticRefreshInProgress || cliStatusRefreshing {
            guard !Task.isCancelled, Date() < waitUntil else {
                usageNotice = "上一轮额度刷新尚未完成。"; return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let name = current
        let operations = supplied ?? StatusRefreshOperations(
            observe: { _ = await self.observeAccountMetadata(importUsage: false) },
            readCache: { try await self.readSelectedCLIUsageCache() })
        await operations.observe()
        guard current == name else {
            lastRefreshDiagnostics?.outcome = "contextChanged"; return
        }
        let scope = protection.desktopScope
        linkedUsageDetails = nil
        if supplied == nil && !isDemo {
            var desktopIssue: String?
            var desktopSample: Date?
            let desktopProfile = scope == .subscription ? name : nil
            if desktopProfile != nil {
                do {
                    let now = Date()
                    guard desktopManualUsagePolicy.shouldRequest(profile: name, sampledAt: nil, resetsAt: [], active: true,
                                                           trigger: .identityChanged, now: now),
                          usageRefreshPolicy.permitsExplicitRequest(profile: name, now: now) else {
                        throw SafetyError("额度查询冷却中，保留已有数据。")
                    }
                    desktopManualUsagePolicy.began(profile: name, now: now)
                    usageRefreshPolicy.began(profile: name, now: now)
                    desktopSample = try await refreshCurrentDesktopUsage()
                } catch {
                    desktopIssue = error.localizedDescription
                    if let response = error as? DesktopUsageHTTPFailure, response.status == 429 {
                        usageRefreshPolicy.failed(profile: name, now: Date(), retryAfter: response.retryAfter)
                    }
                }
            }
            await observeOfficialDefaultCLI()
            guard current == name, protection.desktopScope == scope else {
                lastRefreshDiagnostics?.outcome = "contextChanged"; return
            }
            await refreshLinkedAccountUsage(initialIssue: desktopIssue, desktopProfile: desktopProfile, desktopSample: desktopSample)
            lastRefreshDiagnostics?.outcome = usageNotice != nil ? "queryIncomplete" : linkedUsageDetails != nil ? "partial" : "completed"
            protection.refreshStatus()
            return
        }
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
