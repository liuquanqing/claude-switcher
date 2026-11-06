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
    static func query(home: URL, binding: CLIBinding, proxy: UsageQueryProxy, country: String,
                      executable: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
                      observe: (String) -> Void = { _ in },
                      run supplied: Runner? = nil) async throws -> OfficialCLIUsageCache {
        observe("checkingIdentity")
        try binding.validate(home: home)
        guard country.count == 2, country.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
            throw SafetyError("目标国家无效，未查询额度。")
        }
        let file = binding.choice == .defaultLogin ? home.appendingPathComponent(".claude.json") : binding.directory.appendingPathComponent(".claude.json")
        func identity() throws -> CLIIdentity? {
            do { return try OfficialCLIUsageCache.identity(in: Data(contentsOf: file)) }
            catch { throw SafetyError("CLI 账号尚未对应，保留原额度。") }
        }
        guard try identity()?.samePrincipal(as: binding.identity) == true else {
            throw SafetyError("CLI 账号尚未对应，保留原额度。")
        }
        let old = try? OfficialCLIUsageCache.read(Data(contentsOf: file))
        let started = Date()
        if let old, (0..<30).contains(started.timeIntervalSince(old.fetchedAt)) { observe("freshCache"); return old }
        var env = CLITerminalLaunch.environment(home: home, directory: binding.directory, inherited: inherited)
        env = proxy.environment(env)
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
        guard try identity()?.samePrincipal(as: binding.identity) == true else {
            throw SafetyError("查询前 CLI 账号发生变化，保留原额度。")
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
        } catch OfficialCLIUsageOutput.Failure.invalidReading {
            observe("invalidNativeReading")
            throw SafetyError("官方 CLI 未返回新的对应账号额度，保留原数据。")
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
        if let nativeSample {
            // Text output carries no account UUID. Ask the same official CLI,
            // with the same directory and auth overrides, before assigning it.
            observe("confirmingNativeIdentity")
            let status = try await child(executable.path, ["--setting-sources", "", "auth", "status"])
            guard !status.timedOut, status.status == 0,
                  let report = try? CLIReportedStatus(data: Data(status.text.utf8)),
                  report.usesConfigurationDirectory(binding.directory),
                  report.loggedIn, report.authMethod == "claude.ai",
                  report.savedRecord(matching: binding.identity)?.samePrincipal(as: binding.identity) == true,
                  try identity()?.samePrincipal(as: binding.identity) == true else {
                observe("nativeIdentityUnconfirmed")
                throw SafetyError("CLI 账号尚未对应，保留原额度。")
            }
            observe("nativeOutputRead"); return nativeSample
        }
        observe("noNewReading")
        throw SafetyError("官方 CLI 未返回新的对应账号额度，保留原数据。")
    }
}

@MainActor extension Store {
    func refreshLinkedAccountUsage() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let repo = CLIBindingRepository(file: protection.files.directory.appendingPathComponent("cli-bindings.json"), home: home)
        let captured = profiles.compactMap { p -> (String, CLIIdentity)? in
            guard let id = p.snapshot?.identity, id.isComplete else { return nil }; return (p.name, id)
        }
        var failures: [String] = []
        var selected: [(String, CLIIdentity, CLIBinding)] = []
        for (name, identity) in captured {
            do {
                guard captured.filter({ $0.1.samePrincipal(as: identity) }).count == 1 else {
                    throw SafetyError("账号身份对应多个档案，暂不查询额度。")
                }
                let binding: CLIBinding
                if let saved = try repo.load(identity) { binding = saved }
                else {
                    let document = home.appendingPathComponent(".claude.json")
                    guard let bytes = try? Data(contentsOf: document),
                          try OfficialCLIUsageCache.identity(in: bytes)?.samePrincipal(as: identity) == true else { continue }
                    binding = CLIBinding(identity: identity, choice: .defaultLogin, directory: home.appendingPathComponent(".claude"))
                }
                selected.append((name, identity, binding))
            } catch { failures.append(name + "：" + error.localizedDescription) }
        }
        guard !selected.isEmpty else {
            usageNotice = failures.first ?? "尚无可查询的 CLI 关联，保留原额度。"; return
        }
        do {
            let gate = await protection.preflight(target: .subscriptionUsage)
            guard gate.allowed else { usageNotice = gate.message; return }
            guard let country = protection.activeCountry else { throw SafetyError("目标国家未设置。") }
            let proxyText = try await Task.detached { try LocalCommand.run("/usr/sbin/scutil", ["--proxy"]).1 }.value
            let proxy = try UsageQueryProxy.system(proxyText)
            let executable = try CLITerminalLaunch.executable(home: home)
            for (name, identity, binding) in selected {
                guard !updating, busy == nil else { break }
                guard let saved = try? protection.files.loadConfig(), saved.enabled, saved.expectedCountry == country else {
                    failures.append("保护配置已变化，已停止后续查询。"); break
                }
                guard usageRefreshPolicy.shouldRequest(profile: name, sampledAt: nil, resetsAt: [], active: true, trigger: .identityChanged, now: Date()),
                      usageRefreshPolicy.permitsExplicitRequest(profile: name, now: Date()) else { continue }
                usageRefreshPolicy.began(profile: name, now: Date())
                var stages: [String] = []
                defer {
                    let runs = stages.filter { $0 == "runningOfficialCLI" }.count
                    lastRefreshDiagnostics?.nativeHelperRuns += runs + stages.filter { $0 == "confirmingNativeIdentity" }.count
                    lastRefreshDiagnostics?.freshQuotaRequests += runs
                    lastRefreshDiagnostics?.usageQueries.append(.init(profileIndex: captured.firstIndex(where: { $0.0 == name }) ?? -1, stages: stages))
                }
                do {
                    let sample = try await AccountUsageQuery.query(home: home, binding: binding, proxy: proxy, country: country, executable: executable, observe: { stages.append($0) })
                    guard profiles.first(where: { $0.name == name })?.snapshot?.identity.samePrincipal(as: identity) == true,
                          try repo.load(identity).map({ $0 == binding }) ?? (binding.choice == .defaultLogin) else {
                        throw SafetyError("查询期间账号关联已变化，未采纳结果。")
                    }
                    usageNotice = nil
                    applyOfficialUsage(sample)
                    if let notice = usageNotice { failures.append(name + "：" + notice) }
                } catch {
                    usageRefreshPolicy.failed(profile: name, now: Date())
                    if let index = profiles.firstIndex(where: { $0.name == name && $0.snapshot?.identity.samePrincipal(as: identity) == true }) {
                        profiles[index].finishUsageRefresh(.failure(error))
                    }
                    failures.append(name + "：" + error.localizedDescription)
                }
            }
            usageNotice = failures.isEmpty ? nil : failures.joined(separator: "\n")
        } catch { usageNotice = error.localizedDescription }
    }
}
