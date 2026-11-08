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
    var probes = 0, queries = 0, authChecks = 0
    let report = String(decoding: try CLIJSON.encode(["loggedIn": true, "authMethod": "claude.ai",
        "configDirectory": binding.directory.path, "accountId": "fake-B", "orgId": "fake-org"]), as: UTF8.self)
    let executable = URL(fileURLWithPath: "/fixture/claude")
    let success: AccountUsageQuery.Runner = { path, args, env in
        require(path.path == "/usr/bin/sandbox-exec" && args[1] == proxy.sandbox, "every helper is network constrained")
        require(env["NO_PROXY"] == "" && env["HTTPS_PROXY"] == proxy.url && env["ANTHROPIC_API_KEY"] == nil,
                "ambient bypass and third-party auth cannot select another route")
        require(env["CLAUDE_CONFIG_DIR"] == binding.directory.path, "B is queried in B's existing directory")
        require(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil, "usage requests are not silently disabled by a cache-only environment")
        if args[2] == "/usr/bin/curl" { probes += 1; return .init(status: 0, text: "loc=SG\n", timedOut: false) }
        if args.contains("auth") { authChecks += 1; return .init(status: 0, text: report, timedOut: false) }
        queries += 1; try write(at: Date()); return .init(status: 0, text: "fictional usage", timedOut: false)
    }
    let result = try await AccountUsageQuery.query(home: root, binding: binding, proxy: proxy, country: "SG", executable: executable,
        inherited: ["ANTHROPIC_API_KEY":"fake-key", "NO_PROXY":"*", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1"], run: success)
    require(probes == 3 && authChecks == 1 && queries == 1 && result.session == nil && result.weekly?.used == 22, "verified route and login permit one query; weekly-only plans remain supported")
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
                if args.contains("auth") { return .init(status: 0, text: report, timedOut: false) }
                if failure == "identityChanged" { try write("fake-C", at: Date()) }
                return .init(status: 0, text: "", timedOut: false)
            })
            preconditionFailure("unsafe or stale result accepted")
        } catch { checks += 1 }
        if ["wrongCountry", "noCountry", "timeout"].contains(failure) { require(!startedCLI, "failed route never starts authenticated query") }
    }
    let batch = Store(demo: true)
    let initial = Date().addingTimeInterval(-7200)
    func profile(_ name: String, _ identity: CLIIdentity) -> Profile {
        Profile(name: name, snapshot: Snapshot(accountID: identity.accountID, organizationID: identity.organizationID,
            weekly: Window(used: 10, resetsAt: nil), fetchedAt: initial), signedIn: true)
    }
    let a = CLIIdentity(accountID: "fake-A", organizationID: "fake-org", email: nil)
    let c = CLIIdentity(accountID: "fake-C", organizationID: "fake-org", email: nil)
    let d = CLIIdentity(accountID: "fake-D", organizationID: "fake-org", email: nil)
    batch.profiles = [profile("A", a), profile("B", identity), profile("C", c), profile("D", d),
                      Profile(name: "Empty", snapshot: nil, signedIn: false)]
    let repository = CLIBindingRepository(file: root.appendingPathComponent("fixture-bindings.json"), home: root)
    let aBinding = CLIBinding(identity: a, choice: .defaultLogin, directory: try CLIBinding.directory(for: .defaultLogin, identity: a, home: root))
    let dBinding = CLIBinding(identity: d, choice: .isolated, directory: try CLIBinding.directory(for: .isolated, identity: d, home: root))
    try FileManager.default.createDirectory(at: dBinding.directory, withIntermediateDirectories: true)
    try repository.save(binding)
    try CLIJSON.encode(["oauthAccount": ["accountUuid": "fake-A", "organizationUuid": "fake-org"]]).write(to: defaultLogin)
    let cacheDate = Date().addingTimeInterval(-4)
    try CLIJSON.encode(["oauthAccount": ["accountUuid": "fake-D", "organizationUuid": "fake-org"],
        "cachedUsageUtilization": ["accountUuid": "fake-D", "fetchedAtMs": cacheDate.timeIntervalSince1970 * 1000,
        "utilization": ["seven_day_sonnet": ["utilization": 31]]]])
        .write(to: AccountUsageQuery.document(for: dBinding, home: root))
    try write()
    var requested: [CLIBinding] = []
    let freshDate = Date()
    await batch.refreshLinkedAccountUsage(repository: repository, prepare: {
        require(batch.profiles[3].snapshot?.weeklySonnet?.used == 31, "matching owned cache is adopted before any route work")
        return PreparedAccountUsageQuery(canContinue: { true }, read: { target, _ in
            requested.append(target)
            if target == aBinding { throw AccountUsageQuery.Failure.loginRequired }
            return try OfficialCLIUsageOutput.read("Current week (Fable): 35% used", identity: target.identity, observedAt: freshDate)!
        })
    })
    require(requested == [aBinding, binding], "only stale bound accounts query sequentially; a failure does not stop B")
    require(batch.profiles[0].snapshot?.weekly?.used == 10 && batch.profiles[0].snapshot?.fetchedAt == initial,
            "a failed account retains its original allowance and time")
    require(batch.profiles[0].usageState == .loginRequired && batch.profiles[0].signedIn,
            "CLI signed-out status is shown separately from desktop sign-in and stale quota")
    require(batch.profiles[1].snapshot?.weeklyFable?.used == 35 && batch.profiles[1].snapshot?.weekly == nil,
            "B's model allowance is not passed off as a total weekly allowance")
    require(batch.usageNotice == nil && batch.linkedUsageDetails?.contains("C：") == true
            && batch.linkedUsageDetails?.contains("Empty") == false && batch.lastRefresh == freshDate,
            "a partial refresh preserves its successful time, reports the unlinked account and ignores empty slots")
    await batch.refreshLinkedAccountUsage(repository: repository, prepare: {
        preconditionFailure("no request during cooldown or for fresh local cache")
    })
    require(batch.profiles[1].snapshot?.weeklyFable?.used == 35, "repeated clicks in cooldown retain the newest sample")
    let blocked = Store(demo: true)
    blocked.profiles = [profile("A", a), profile("D", d)]
    await blocked.refreshLinkedAccountUsage(repository: repository, prepare: {
        throw SafetyError("fixture route failure")
    })
    require(blocked.profiles[0].snapshot?.fetchedAt == initial && blocked.profiles[1].snapshot?.weeklySonnet?.used == 31,
            "route failure blocks network reads but does not discard usable local cache")
    let desktop = Store(demo: true)
    await desktop.updateCLIStatus { .init(status: .needsLogin) }
    let owner = desktop.active!.snapshot!.identity
    await desktop.updateCLIStatus { .init(status: .unverified, identity: owner, metadataOnly: true) }
    require(desktop.cliStatus == .needsLogin, "a local account record cannot erase a fresh official signed-out report")
    var revision = "one"
    var events: [String] = []
    var responseOwner = owner.accountID!
    var revokeBeforeCommit = false
    let access = "fixture-desktop-credential"
    var prepared = DesktopUsageOperations(context: {
        .init(profile: desktop.current, account: owner.accountID, loginRevision: revision)
    }, authorizeRoute: {
        events.append("route")
    }, readAccess: {
        events.append("readAccess")
        return access
    }, get: { endpoint, presented in
        require(presented == access, "the verified desktop token is used only by the prepared request")
        events.append(endpoint.rawValue)
        if endpoint == .profile {
            return try CLIJSON.encode(["account": ["uuid": responseOwner], "organization": ["uuid": owner.organizationID!]])
        }
        if revokeBeforeCommit { revision = "two" }
        return try CLIJSON.encode(["seven_day_fable": ["utilization": 38]])
    })
    let desktopTime = try await desktop.refreshCurrentDesktopUsage(operations: prepared)
    require(events == ["route", "readAccess", "profile", "usage"] && desktop.cliStatus == .needsLogin
            && desktop.active?.snapshot?.weeklyFable?.used == 38 && desktop.lastRefresh == desktopTime,
            "desktop-only login updates the active quota without changing independent CLI status")
    events = []
    desktop.profiles[0].snapshot?.identityTokenDigest = nil
    responseOwner = "wrong-fixture-account"
    do {
        _ = try await desktop.refreshCurrentDesktopUsage(operations: prepared)
        preconditionFailure("quota must not be sent for a mismatched desktop login")
    } catch { require(events == ["route", "readAccess", "profile"] && desktop.lastRefresh == desktopTime, "identity mismatch retains last sample") }
    responseOwner = owner.accountID!
    revokeBeforeCommit = true
    do {
        _ = try await desktop.refreshCurrentDesktopUsage(operations: prepared)
        preconditionFailure("a changed desktop login must discard an in-flight sample")
    } catch { require(desktop.lastRefresh == desktopTime, "a switched login cannot adopt the sample") }
    events = []
    prepared = .init(context: prepared.context, authorizeRoute: { throw SafetyError("wrong fixture region") },
                     readAccess: prepared.readAccess, get: prepared.get)
    do {
        _ = try await desktop.refreshCurrentDesktopUsage(operations: prepared)
        preconditionFailure("bad route must not query desktop usage")
    } catch { require(events.isEmpty, "bad route stops before credential access or HTTP calls") }
    do {
        _ = try DesktopUsageHTTP.body("HTTP/2 429\r\nRetry-After: 120\r\n\r\n{}", now: desktopTime)
        preconditionFailure("429 cannot be considered usage")
    } catch let failure as DesktopUsageHTTPFailure {
        require(failure.retryAfter == desktopTime.addingTimeInterval(120), "desktop requests honor Retry-After")
    }
    let pipe = try await BoundedCLICommand.run(home: root, executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
        inherited: [:], timeoutSeconds: 3, graceSeconds: 1, input: Data("fixture-pipe-data".utf8))
    require(pipe.status == 0 && pipe.text == "fixture-pipe-data", "anonymous pipe supplies input and delivers EOF without a file")
    return checks
}
