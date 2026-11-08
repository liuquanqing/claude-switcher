import Foundation
import SwitcherCore

struct DesktopUsageHTTPFailure: LocalizedError {
    let status: Int
    let retryAfter: Date?
    var errorDescription: String? {
        switch status {
        case 429: return "桌面额度查询受限，请稍后重试。"
        case 401, 403: return "桌面额度接口未接受此登录，请在 Claude 设置中查看用量。"
        default: return "桌面额度暂不可用，保留原数据。"
        }
    }
}

enum DesktopUsageHTTP {
    enum Endpoint: String { case profile, usage }
    static let unavailable = "桌面额度暂不可用，保留原数据。"

    static func run(_ arguments: [String], proxy: UsageQueryProxy, home: URL, input: Data? = nil) async throws -> String {
        let result = try await BoundedCLICommand.run(home: home, executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", proxy.sandbox, "/usr/bin/curl", "-q", "--silent", "--max-time", "10", "--proxy", proxy.url,
                        "--noproxy", "", "--proto", "=https"] + arguments,
            inherited: ["PATH": "/usr/bin:/bin", "HOME": home.path], timeoutSeconds: 12, graceSeconds: 1,
            combineStderr: false, input: input)
        guard !result.timedOut, result.status == 0 else { throw SafetyError(unavailable) }
        return result.text
    }

    static func get(_ endpoint: Endpoint, access: String, proxy: UsageQueryProxy, home: URL) async throws -> Data {
        guard access.range(of: #"^[A-Za-z0-9._~+/=-]{1,3000}$"#, options: .regularExpression) != nil else {
            throw SafetyError("桌面登录凭据格式无法确认，未查询额度。")
        }
        // curl config is supplied over a private pipe; no token in arguments, env or files.
        let header = Data("header = \"Authorization: Bearer \(access)\"\n".utf8)
        let response = try await run(["--config", "-", "--include", "--suppress-connect-headers", "--max-filesize", "32768",
            "--header", "Accept: application/json", "--header", "anthropic-beta: oauth-2025-04-20",
            "--user-agent", "claude-switcher", "https://api.anthropic.com/api/oauth/\(endpoint.rawValue)"],
            proxy: proxy, home: home, input: header)
        return try body(response)
    }

    static func body(_ response: String, now: Date = Date()) throws -> Data {
        guard let split = response.range(of: "\r\n\r\n") else { throw SafetyError(unavailable) }
        let headers = response[..<split.lowerBound].components(separatedBy: "\r\n")
        guard let first = headers.first, first.hasPrefix("HTTP/"),
              let code = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            throw SafetyError(unavailable)
        }
        guard code == 200 else {
            let raw = headers.first(where: { $0.lowercased().hasPrefix("retry-after:") })?
                .dropFirst("retry-after:".count).trimmingCharacters(in: .whitespaces)
            let seconds = raw.flatMap(Double.init)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let date = seconds.flatMap { $0.isFinite && $0 > 0 ? now.addingTimeInterval($0) : nil }
                ?? raw.flatMap { formatter.date(from: $0) }
            throw DesktopUsageHTTPFailure(status: code,
                retryAfter: code == 429 ? (date.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(900)) : nil)
        }
        return Data(response[split.upperBound...].utf8)
    }
}

struct DesktopUsageContext: Equatable {
    let profile: String
    let account: String?
    let loginRevision: String
}

@MainActor struct DesktopUsageOperations {
    let context: () throws -> DesktopUsageContext
    let authorizeRoute: () async throws -> Void
    let readAccess: () async throws -> String?
    let get: (DesktopUsageHTTP.Endpoint, String) async throws -> Data
}

@MainActor extension Store {
    private func desktopUsageOperations(name: String, allowInteraction: Bool) async throws -> DesktopUsageOperations {
        let decision = await protection.preflight(target: .subscriptionUsage)
        guard decision.allowed else { throw SafetyError(decision.message) }
        let files = protection.files
        let config = try files.loadConfig()
        guard config.enabled, config.expectedCountry == decision.expectedCountry else {
            throw SafetyError("保护配置已变化，已停止后续查询。")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let proxyText = try await Task.detached { try LocalCommand.run("/usr/sbin/scutil", ["--proxy"]).1 }.value
        let proxy = try UsageQueryProxy.system(proxyText)
        func routeStillApproved() throws {
            guard try files.loadConfig() == config, files.loadReceipt()?.isFresh(for: config) == true else {
                throw SafetyError("保护配置已变化，已停止后续查询。")
            }
        }
        return .init(context: {
            guard self.current == name, try confirmedCurrentProfile() == name,
                  DesktopModeInspector.read(support: support) == .subscription else {
                throw SafetyError("查询期间订阅账号已变化，未采纳旧额度。")
            }
            let directory = try liveDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directory.isDirectory == true, directory.isSymbolicLink != true else {
                throw SafetyError("桌面档案路径不是普通目录，未读取登录。")
            }
            let object = try CLIJSON.object(Data(contentsOf: liveDir.appendingPathComponent("config.json")))
            guard let encrypted = object["oauth:tokenCacheV2"] as? String, !encrypted.isEmpty else {
                throw SafetyError("没有可用的桌面订阅登录，保留原额度。")
            }
            return DesktopUsageContext(profile: name, account: object["lastKnownAccountUuid"] as? String,
                                       loginRevision: desktopTokenDigest(encrypted))
        }, authorizeRoute: {
            for endpoint in NetworkProbe.traceEndpoints {
                let trace = try await DesktopUsageHTTP.run(["--fail", endpoint], proxy: proxy, home: home)
                guard NetworkObservation.countryFromTrace(trace, httpStatus: 200) == config.expectedCountry else {
                    throw SafetyError("查询出口未通过检查，保留原额度。")
                }
            }
            try routeStillApproved()
        }, readAccess: {
            try await token(for: liveDir, allowInteraction: allowInteraction)
        }, get: { endpoint, access in
            try routeStillApproved()
            return try await DesktopUsageHTTP.get(endpoint, access: access, proxy: proxy, home: home)
        })
    }

    /// Never uses CLI login or a parked profile's desktop token.
    func refreshCurrentDesktopUsage(allowInteraction: Bool = true, operations supplied: DesktopUsageOperations? = nil) async throws -> Date {
        guard !isDemo || supplied != nil else { throw SafetyError("演示模式不读取真实登录。") }
        let name = current
        guard protection.desktopScope == .subscription else { throw SafetyError("当前模式尚未确认，未查询额度。") }
        let ops: DesktopUsageOperations
        if let supplied { ops = supplied }
        else { ops = try await desktopUsageOperations(name: name, allowInteraction: allowInteraction) }
        let before = try ops.context()
        func assertCurrent() throws {
            guard before.profile == name, current == name, protection.desktopScope == .subscription,
                  try ops.context() == before else {
                throw SafetyError("查询期间订阅账号已变化，未采纳旧额度。")
            }
        }
        lastRefreshDiagnostics?.desktopUsageStages.append("checkingRoute")
        try await ops.authorizeRoute()
        try assertCurrent()
        guard let access = try await ops.readAccess() else {
            throw SafetyError("没有可用的桌面订阅登录，保留原额度。")
        }
        try assertCurrent()
        let digest = desktopTokenDigest(access)
        let saved = active?.snapshot
        let identity: CLIIdentity
        var plan = saved?.plan
        if let saved, saved.identity.isComplete, saved.identityTokenDigest == digest {
            identity = saved.identity
        } else {
            lastRefreshDiagnostics?.desktopUsageStages.append("checkingIdentity")
            let profile = try CLIJSON.object(await ops.get(.profile, access))
            identity = CLIIdentity.profile(profile)
            plan = planName(profile["organization"] as? [String: Any]) ?? plan
        }
        guard identity.isComplete,
              saved?.identity.isComplete != true || saved?.identity.samePrincipal(as: identity) == true,
              before.account == nil || CLIReportedStatus.sameAccountRecord(identity,
                  CLIIdentity(accountID: before.account, organizationID: nil, email: nil)) == true,
              !profiles.contains(where: { $0.name != name && CLIReportedStatus.sameAccountRecord($0.snapshot?.identity, identity) == true }) else {
            throw SafetyError("当前订阅身份未匹配，未改写额度。")
        }
        try assertCurrent()
        lastRefreshDiagnostics?.desktopUsageStages.append("readingDesktopUsage")
        lastRefreshDiagnostics?.freshQuotaRequests += 1
        let sample = try SubscriptionUsageSample.read(await ops.get(.usage, access))
        try assertCurrent()
        guard let index = profiles.firstIndex(where: { $0.name == name }) else {
            throw SafetyError("查询期间订阅账号已变化，未采纳旧额度。")
        }
        let time = Date()
        var snapshot = profiles[index].snapshot ?? Snapshot(fetchedAt: .distantPast)
        snapshot.accountID = identity.accountID
        snapshot.organizationID = identity.organizationID
        snapshot.email = identity.email
        snapshot.identityTokenDigest = digest
        snapshot.plan = plan
        func window(_ metric: OfficialUsageWindow?) -> Window? { metric.map { Window(used: $0.used, resetsAt: $0.resetsAt) } }
        snapshot.session = window(sample.session)
        snapshot.weekly = window(sample.weekly)
        snapshot.weeklyOpus = window(sample.weeklyOpus)
        snapshot.weeklySonnet = window(sample.weeklySonnet)
        snapshot.weeklyFable = window(sample.weeklyFable)
        snapshot.fetchedAt = time
        acceptSubscriptionUsageResult(.success(snapshot), for: name, contextUnchanged: true)
        cliConnection.contextDidChange()
        lastRefreshDiagnostics?.desktopUsageStages.append("desktopSampleAdopted")
        return time
    }
}
