import Foundation
import SwitcherCore

@MainActor struct StatusRefreshOperations {
    let observe: () async -> Void
    let desktop: (String) -> DesktopUsageOperations
}

@MainActor extension Store {
    func refreshAllStatuses(operations supplied: StatusRefreshOperations? = nil) async {
        guard !updating, busy == nil, !refreshing, !statusRefreshInProgress else { return }
        guard !isDemo || supplied != nil else { return }
        statusRefreshInProgress = true
        lastRefreshDiagnostics = RefreshDiagnostics()
        defer {
            statusRefreshInProgress = false
            lastRefreshDiagnostics?.completedAt = Date()
            if !isDemo { lastRefreshDiagnostics?.save() }
            onChange?()
        }
        let waitUntil = Date().addingTimeInterval(30)
        while automaticRefreshInProgress || cliStatusRefreshing {
            guard !Task.isCancelled, Date() < waitUntil else {
                usageNotice = "上一轮额度刷新尚未完成。"; return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let selected = current
        if let supplied { await supplied.observe() }
        else { _ = await observeAccountMetadata(importUsage: false) }
        let scope = protection.desktopScope
        usageNotice = nil
        linkedUsageDetails = nil
        guard current == selected else {
            lastRefreshDiagnostics?.outcome = "contextChanged"; return
        }
        guard scope != .unknown else {
            usageNotice = "当前模式尚未确认，未查询额度。"
            lastRefreshDiagnostics?.outcome = "queryIncomplete"
            return
        }
        let names = profiles.filter {
            $0.signedIn || $0.snapshot != nil || (scope == .subscription && $0.name == selected)
        }.map(\.name)
        var issues: [String] = []
        var newest: Date?
        for name in names {
            guard current == selected, protection.desktopScope == scope, !Task.isCancelled else {
                lastRefreshDiagnostics?.outcome = "contextChanged"; return
            }
            let now = Date()
            if !desktopManualUsagePolicy.shouldRequest(profile: name, sampledAt: nil, resetsAt: [], active: true,
                                                       trigger: .identityChanged, now: now)
                || !usageRefreshPolicy.permitsExplicitRequest(profile: name, now: now) {
                issues.append(name + "：额度查询冷却中，保留已有数据。")
                continue
            }
            desktopManualUsagePolicy.began(profile: name, now: now)
            usageRefreshPolicy.began(profile: name, now: now)
            do {
                let sampledAt = try await refreshDesktopUsage(for: name, operations: supplied?.desktop(name))
                newest = max(newest ?? sampledAt, sampledAt)
            } catch {
                guard current == selected, protection.desktopScope == scope, !Task.isCancelled else {
                    lastRefreshDiagnostics?.outcome = "contextChanged"; return
                }
                if let response = error as? DesktopUsageHTTPFailure, response.status == 429 {
                    usageRefreshPolicy.failed(profile: name, now: Date(), retryAfter: response.retryAfter)
                }
                if let index = profiles.firstIndex(where: { $0.name == name }) {
                    profiles[index].finishUsageRefresh(.failure(error))
                }
                issues.append(name + "：" + error.localizedDescription)
            }
        }
        let detail = issues.isEmpty ? nil : issues.joined(separator: "\n")
        if let newest {
            lastRefresh = newest
            linkedUsageDetails = detail
        } else {
            usageNotice = detail ?? "没有可查询的桌面订阅账号。"
        }
        lastRefreshDiagnostics?.outcome = usageNotice != nil ? "queryIncomplete" : detail != nil ? "partial" : "completed"
        protection.refreshStatus()
    }
}
