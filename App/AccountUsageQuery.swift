import Foundation
import SwitcherCore

/// One explicitly requested CLI read. Only this child may reach the selected
/// loopback HTTP proxy; the user's terminals and system routing are untouched.
struct UsageQueryProxy: Equatable {
    let host: String
    let port: Int
    var url: String { "http://\(host):\(port)" }
    var sandbox: String {
        "(version 1) (allow default) (deny network*) (allow network-outbound (remote ip \"localhost:\(port)\"))"
    }
    init(host: String, port: Int) throws {
        guard host == "127.0.0.1", (1...65535).contains(port) else {
            throw SafetyError("额度查询需要本机 HTTP 代理，未发起请求。")
        }
        self.host = host; self.port = port
    }
    static func system(_ text: String) throws -> Self {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        for prefix in ["HTTPS", "HTTP"] where fields[prefix + "Enable"] == "1" {
            if let host = fields[prefix + "Proxy"], let port = fields[prefix + "Port"].flatMap(Int.init) {
                return try Self(host: host == "localhost" ? "127.0.0.1" : host, port: port)
            }
        }
        throw SafetyError("未发现本机 HTTP 代理，保留原额度。")
    }
    func environment(_ inherited: [String: String]) -> [String: String] {
        var env = inherited
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { env[key] = url }
        for key in ["NO_PROXY", "no_proxy"] { env[key] = "" }
        return env
    }
}

enum AccountUsageQuery {
    typealias Runner = (URL, [String], [String: String]) async throws -> BoundedCLICommand.Output

    enum Failure: LocalizedError, Equatable {
        case loginUnconfirmed, loginRequired, noReading
        var errorDescription: String? {
            switch self {
            case .loginUnconfirmed: return "CLI 订阅登录尚未确认，保留原额度。"
            case .loginRequired: return "请在对应 Claude Code 中登录后再刷新，原额度已保留。"
            case .noReading: return "官方 CLI 未返回新的对应账号额度，保留原数据。"
            }
        }
    }

    static func document(for binding: CLIBinding, home: URL) -> URL {
        (binding.choice == .defaultLogin ? home : binding.directory).appendingPathComponent(".claude.json")
    }

    static func matchingBinding(for identity: CLIIdentity, profile: String, repository: CLIBindingRepository) throws -> CLIBinding? {
        if let saved = try repository.load(identity) { return saved }
        let home = repository.home
        let owned = try CLIBinding.directory(for: .isolated, identity: identity, home: home)
        var directories: [(CLIBindingChoice, URL)] = [(.isolated, owned)]
        if ProfileTransaction.validName(profile) {
            let legacy = owned.deletingLastPathComponent().appendingPathComponent(profile)
            if legacy.path != owned.path, FileManager.default.fileExists(atPath: legacy.path) {
                directories.append((.isolated, legacy))
            }
        }
        directories.append((.defaultLogin, try CLIBinding.directory(for: .defaultLogin, identity: identity, home: home)))
        for (choice, directory) in directories {
            let candidate = CLIBinding(identity: identity, choice: choice, directory: directory)
            try candidate.validate(home: home)
            guard let bytes = try? Data(contentsOf: document(for: candidate, home: home)),
                  (try? OfficialCLIUsageCache.identity(in: bytes))?.samePrincipal(as: identity) == true else { continue }
            return candidate
        }
        return nil
    }

    static func isFresh(_ sample: OfficialCLIUsageCache, now: Date = Date()) -> Bool {
        (0..<30).contains(now.timeIntervalSince(sample.fetchedAt))
    }

    static func query(home: URL, binding: CLIBinding, proxy: UsageQueryProxy, country: String,
                      executable: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
                      observe: (String) -> Void = { _ in },
                      run supplied: Runner? = nil) async throws -> OfficialCLIUsageCache {
        observe("checkingIdentity")
        try binding.validate(home: home)
        guard country.count == 2, country.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
            throw SafetyError("目标国家无效，未查询额度。")
        }
        let file = document(for: binding, home: home)
        func identity() throws -> CLIIdentity? {
            do { return try OfficialCLIUsageCache.identity(in: Data(contentsOf: file)) }
            catch { throw SafetyError("CLI 账号尚未对应，保留原额度。") }
        }
        guard try identity()?.samePrincipal(as: binding.identity) == true else {
            throw SafetyError("CLI 账号尚未对应，保留原额度。")
        }
        let old = try? OfficialCLIUsageCache.read(Data(contentsOf: file))
        let started = Date()
        if let old, isFresh(old, now: started) { observe("freshCache"); return old }
        var env = CLITerminalLaunch.environment(home: home, directory: binding.directory, inherited: inherited)
        env = proxy.environment(env)
        env.removeValue(forKey: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
        for key in ["DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_AUTO_MEMORY"] { env[key] = "1" }
        let run: Runner = supplied ?? { executable, arguments, environment in
            try await BoundedCLICommand.run(home: home, executable: executable, arguments: arguments,
                inherited: environment, timeoutSeconds: 45, graceSeconds: 2, combineStderr: false)
        }
        func child(_ executable: String, _ arguments: [String]) async throws -> BoundedCLICommand.Output {
            try await run(URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", proxy.sandbox, executable] + arguments, env)
        }
        // Country probes use the exact proxy the CLI child is constrained to.
        // No redirect or direct retry. All Claude routing domains must agree.
        observe("checkingRoute")
        for endpoint in NetworkProbe.traceEndpoints {
            let result = try await child("/usr/bin/curl", ["-q", "--silent", "--show-error", "--fail", "--max-time", "8",
                "--proxy", proxy.url, "--noproxy", "", "--proto", "=https", endpoint])
            guard !result.timedOut, result.status == 0,
                  NetworkObservation.countryFromTrace(result.text, httpStatus: 200) == country else {
                throw SafetyError("查询出口未通过检查，保留原额度。")
            }
        }
        guard let localIdentity = try identity(), localIdentity.samePrincipal(as: binding.identity) else {
            throw SafetyError("查询前 CLI 账号发生变化，保留原额度。")
        }
        observe("checkingNativeLogin")
        let status = try await child(executable.path, ["--setting-sources", "", "auth", "status"])
        guard !status.timedOut, [0, 1].contains(status.status),
              let report = try? CLIReportedStatus(data: Data(status.text.utf8)),
              (status.status == 0) == report.loggedIn,
              try identity()?.samePrincipal(as: binding.identity) == true else {
            observe("nativeIdentityUnconfirmed")
            throw Failure.loginUnconfirmed
        }
        let match = CLIBindingPolicy.assess(report, binding: binding, metadata: localIdentity)
        if match == .notLoggedIn { observe("nativeLoginRequired"); throw Failure.loginRequired }
        guard status.status == 0, match == .matched else {
            observe("nativeIdentityUnconfirmed")
            throw Failure.loginUnconfirmed
        }
        observe("runningOfficialCLI")
        let result = try await child(executable.path, ["-p", "/usage", "--output-format", "json", "--tools", "",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "", "--no-session-persistence",
            "--permission-prompts", "none"])
        observe("nativeExit:\(result.status)")
        observe(result.timedOut ? "nativeTimeout" : result.status == 0 ? "nativeCompleted" : "nativeExitFailure")
        guard !result.timedOut, result.status == 0 else {
            throw SafetyError("额度查询未完成，保留原数据。")
        }
        guard try identity()?.samePrincipal(as: binding.identity) == true else {
            throw SafetyError("查询期间账号关联已变化，未采纳结果。")
        }
        observe("readingNativeOutput")
        let nativeSample: OfficialCLIUsageCache?
        do {
            nativeSample = try OfficialCLIUsageOutput.read(result.text, identity: binding.identity, observedAt: Date())
        } catch OfficialCLIUsageOutput.Failure.loginRequired {
            observe("nativeLoginRequired")
            throw Failure.loginRequired
        } catch OfficialCLIUsageOutput.Failure.invalidReading {
            observe("invalidNativeReading")
            throw Failure.noReading
        } catch {
            observe("nativeReportedError")
            throw SafetyError("额度查询未完成，保留原数据。")
        }
        if let sample = try? OfficialCLIUsageCache.read(Data(contentsOf: file)),
           sample.identity.samePrincipal(as: binding.identity), sample.fetchedAt <= Date(),
           sample.fetchedAt >= started.addingTimeInterval(-1), sample.fetchedAt > (old?.fetchedAt ?? .distantPast) {
            observe("cacheUpdated")
            return sample
        }
        // A successful native /usage response need not update .claude.json.
        if let nativeSample { observe("nativeOutputRead"); return nativeSample }
        observe("noNewReading")
        throw Failure.noReading
    }
}

@MainActor struct PreparedAccountUsageQuery {
    let canContinue: () -> Bool
    let read: (CLIBinding, (String) -> Void) async throws -> OfficialCLIUsageCache
}

@MainActor extension Store {
    private func prepareAccountUsageQuery(home: URL) async throws -> PreparedAccountUsageQuery {
        let gate = await protection.preflight(target: .subscriptionUsage)
        guard gate.allowed else { throw SafetyError(gate.message) }
        guard let country = protection.activeCountry else { throw SafetyError("目标国家未设置。") }
        let proxyText = try await Task.detached { try LocalCommand.run("/usr/sbin/scutil", ["--proxy"]).1 }.value
        let proxy = try UsageQueryProxy.system(proxyText)
        let executable = try CLITerminalLaunch.executable(home: home)
        return PreparedAccountUsageQuery(canContinue: {
            guard let saved = try? self.protection.files.loadConfig() else { return false }
            return saved.enabled && saved.expectedCountry == country
        }, read: { binding, observe in
            try await AccountUsageQuery.query(home: home, binding: binding, proxy: proxy, country: country,
                                              executable: executable, observe: observe)
        })
    }

    func refreshLinkedAccountUsage(repository supplied: CLIBindingRepository? = nil,
                                   prepare: (() async throws -> PreparedAccountUsageQuery)? = nil,
                                   initialIssue: String? = nil, desktopProfile: String? = nil,
                                   desktopSample: Date? = nil) async {
        let repo = supplied ?? CLIBindingRepository(file: protection.files.directory.appendingPathComponent("cli-bindings.json"),
                                                     home: FileManager.default.homeDirectoryForCurrentUser)
        let captured = profiles
        let context = (current, protection.desktopScope)
        var issues: [String] = initialIssue.map { [$0] } ?? []
        var selected: [(Int, CLIBinding)] = []
        var newest = desktopSample
        func profileIndex(_ name: String, _ identity: CLIIdentity) -> Int? {
            guard (current, protection.desktopScope) == context else { return nil }
            return profiles.firstIndex { $0.name == name && $0.snapshot?.identity.samePrincipal(as: identity) == true }
        }
        func adopt(_ sample: OfficialCLIUsageCache, for name: String, binding: CLIBinding) throws {
            guard let index = profileIndex(name, binding.identity), sample.fetchedAt <= Date(),
                  sample.identity.samePrincipal(as: binding.identity),
                  try AccountUsageQuery.matchingBinding(for: binding.identity, profile: name, repository: repo) == binding else {
                throw SafetyError("查询期间账号关联已变化，未采纳结果。")
            }
            guard let stored = profiles[index].snapshot, sample.fetchedAt >= stored.fetchedAt else { return }
            usageNotice = nil
            applyOfficialUsage(sample)
            if let usageNotice { throw SafetyError(usageNotice) }
            newest = max(newest ?? .distantPast, sample.fetchedAt)
        }
        defer {
            if let newest { lastRefresh = newest }
            let detail = issues.isEmpty ? nil : issues.joined(separator: "\n")
            usageNotice = newest == nil ? (detail ?? "本轮没有新的订阅额度，保留原数据。") : nil
            linkedUsageDetails = newest == nil ? nil : detail
        }
        for (offset, p) in captured.enumerated() where p.signedIn && p.name != desktopProfile {
            do {
                guard let identity = p.snapshot?.identity, identity.isComplete else {
                    if p.name != context.0 || initialIssue == nil { issues.append(p.name + "：桌面账号身份尚未确认，保留原额度。") }
                    continue
                }
                guard captured.filter({ CLIReportedStatus.sameAccountRecord($0.snapshot?.identity, identity) == true }).count == 1 else {
                    throw SafetyError("账号身份对应多个档案，暂不查询额度。")
                }
                guard let binding = try AccountUsageQuery.matchingBinding(for: identity, profile: p.name, repository: repo) else {
                    throw SafetyError("CLI 账号尚未对应，保留原额度。")
                }
                if let cached = try? await OfficialCLIUsageReader.readBoundCache(home: repo.home, binding: binding, expected: identity),
                   cached.fetchedAt <= Date() {
                    try adopt(cached, for: p.name, binding: binding)
                    if cached.fetchedAt >= (p.snapshot?.fetchedAt ?? .distantPast) {
                        lastRefreshDiagnostics?.quotaCacheAdopted = true
                    }
                    if AccountUsageQuery.isFresh(cached) { continue }
                }
                guard usageRefreshPolicy.shouldRequest(profile: p.name, sampledAt: nil, resetsAt: [], active: true, trigger: .identityChanged, now: Date()),
                      usageRefreshPolicy.permitsExplicitRequest(profile: p.name, now: Date()) else {
                    issues.append(p.name + "：额度查询冷却中，保留已有数据。"); continue
                }
                selected.append((offset, binding))
            } catch { issues.append(p.name + "：" + error.localizedDescription) }
        }
        guard !selected.isEmpty else { return }
        let query: PreparedAccountUsageQuery
        do {
            if let prepare { query = try await prepare() }
            else { query = try await prepareAccountUsageQuery(home: repo.home) }
        } catch { issues.append(error.localizedDescription); return }
        for (offset, binding) in selected {
            let name = captured[offset].name
            guard !updating, busy == nil, query.canContinue() else {
                issues.append("保护配置已变化，已停止后续查询。"); break
            }
            var stages: [String] = []
            defer {
                let runs = stages.filter { $0 == "runningOfficialCLI" }.count
                lastRefreshDiagnostics?.nativeHelperRuns += runs + stages.filter { $0 == "checkingNativeLogin" }.count
                lastRefreshDiagnostics?.freshQuotaRequests += runs
                lastRefreshDiagnostics?.usageQueries.append(.init(profileIndex: offset, stages: stages))
            }
            do {
                guard profileIndex(name, binding.identity) != nil,
                      try AccountUsageQuery.matchingBinding(for: binding.identity, profile: name, repository: repo) == binding else {
                    throw SafetyError("查询期间账号关联已变化，未采纳结果。")
                }
                usageRefreshPolicy.began(profile: name, now: Date())
                try adopt(await query.read(binding, { stages.append($0) }), for: name, binding: binding)
            } catch {
                // A new login or readable output can be repaired by the user.
                // Leave the usual one-minute request spacing, rather than
                // applying the longer backoff for network and service errors.
                if !(error is AccountUsageQuery.Failure) { usageRefreshPolicy.failed(profile: name, now: Date()) }
                if let index = profileIndex(name, binding.identity) { profiles[index].finishUsageRefresh(.failure(error)) }
                issues.append(name + "：" + error.localizedDescription)
            }
        }
    }
}
