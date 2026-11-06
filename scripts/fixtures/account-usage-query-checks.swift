import Foundation
import SwitcherCore

@MainActor func accountUsageQueryChecks() async throws -> Int {
    var checks = 0
    func require(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-query-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = CLIIdentity(accountID: "fake-B", organizationID: "fake-org", email: "b@example.invalid")
    let binding = CLIBinding(identity: identity, choice: .isolated, directory: try CLIBinding.directory(for: .isolated, identity: identity, home: root))
    try FileManager.default.createDirectory(at: binding.directory, withIntermediateDirectories: true)
    let document = binding.directory.appendingPathComponent(".claude.json")
    let defaultLogin = root.appendingPathComponent(".claude.json")
    let preserved = Data("fictional default A login metadata".utf8)
    try preserved.write(to: defaultLogin)
    let history = binding.directory.appendingPathComponent("history.jsonl")
    try Data("fictional history".utf8).write(to: history)
    func write(_ account: String = "fake-B", at date: Date = Date().addingTimeInterval(-3600)) throws {
        let value: [String: Any] = ["oauthAccount": ["accountUuid": account, "organizationUuid": "fake-org"],
            "cachedUsageUtilization": ["accountUuid": account, "fetchedAtMs": date.timeIntervalSince1970 * 1000,
            "utilization": ["five_hour": NSNull(), "seven_day": ["utilization": 22]]]]
        try JSONSerialization.data(withJSONObject: value).write(to: document)
    }
    try write()
    let proxy = try UsageQueryProxy.system("HTTPSEnable : 1\nHTTPSProxy : 127.0.0.1\nHTTPSPort : 9876")
    require(proxy.port == 9876, "system proxy selects explicit loopback endpoint")
    for text in ["", "HTTPSEnable : 0\nHTTPSProxy : 127.0.0.1\nHTTPSPort : 9876", "HTTPSEnable : 1\nHTTPSProxy : example.invalid\nHTTPSPort : 9876"] {
        do { _ = try UsageQueryProxy.system(text); preconditionFailure("unsafe endpoint accepted") } catch { checks += 1 }
    }
    var probes = 0, queries = 0
    let executable = URL(fileURLWithPath: "/fixture/claude")
    let success: AccountUsageQuery.Runner = { path, args, env in
        require(path.path == "/usr/bin/sandbox-exec" && args[1] == proxy.sandbox, "every helper is network constrained")
        require(env["NO_PROXY"] == "" && env["HTTPS_PROXY"] == proxy.url && env["ANTHROPIC_API_KEY"] == nil,
                "ambient bypass and third-party auth cannot select another route")
        require(env["CLAUDE_CONFIG_DIR"] == binding.directory.path, "B is queried in B's existing directory")
        if args[2] == "/usr/bin/curl" { probes += 1; return .init(status: 0, text: "loc=SG\n", timedOut: false) }
        queries += 1; try write(at: Date()); return .init(status: 0, text: "fictional usage", timedOut: false)
    }
    let result = try await AccountUsageQuery.query(home: root, binding: binding, proxy: proxy, country: "SG", executable: executable,
        inherited: ["ANTHROPIC_API_KEY":"fake-key", "NO_PROXY":"*"], run: success)
    require(probes == 3 && queries == 1 && result.session == nil && result.weekly?.used == 22, "three matching routes permit one query and no-five-hour plans remain supported")
    require(try Data(contentsOf: defaultLogin) == preserved, "noncurrent query preserves default A")
    require(try String(contentsOf: history, encoding: .utf8) == "fictional history", "history is retained")
    _ = try await AccountUsageQuery.query(home: root, binding: binding, proxy: proxy, country: "SG", executable: executable,
        run: { _,_,_ in preconditionFailure("fresh sample should not spawn a child") })
    checks += 1
    for failure in ["wrongCountry", "noCountry", "timeout", "staleSample", "identityChanged"] {
        try write();var startedCLI = false
        do {
            _ = try await AccountUsageQuery.query(home: root, binding: binding, proxy: proxy, country: "SG", executable: executable, run: { _,args,_ in
                if args[2] == "/usr/bin/curl" {
                    return .init(status: 0, text: failure == "wrongCountry" ? "loc=JP\n" : failure == "noCountry" ? "" : "loc=SG\n", timedOut: failure == "timeout")
                }
                startedCLI = true
                if failure == "identityChanged" { try write("fake-C", at: Date()) }
                return .init(status: 0, text: "", timedOut: false)
            })
            preconditionFailure("unsafe or stale result accepted")
        } catch { checks += 1 }
        if ["wrongCountry", "noCountry", "timeout"].contains(failure) { require(!startedCLI, "failed route never starts authenticated query") }
    }
    return checks
}
