import Foundation
import SwitcherCore

@MainActor func nativeUsageOutputChecks() async throws -> Int {
    var count = 0
    func require(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    let identity = CLIIdentity(accountID: "fake-account", organizationID: "fake-org", email: "fixture@example.invalid")
    let now = ISO8601DateFormatter().date(from:"2026-11-06T10:00:00Z")!
    let plain = "Current session: 13% used · resets 8pm (Asia/Singapore)\nCurrent week (all models): 46% used · resets Nov 8 at 6pm (Asia/Singapore)"
    let data = try JSONSerialization.data(withJSONObject:["type":"result", "is_error":false, "result":plain])
    let sample = try OfficialCLIUsageOutput.read(String(decoding:data,as:UTF8.self), identity:identity, observedAt:now)
    require(sample?.session?.used == 13 && sample?.weekly?.used == 46, "native JSON result supplies actual percentages without a file write")
    require(sample?.fetchedAt == now && sample?.identity == identity, "only a recognized new response receives a new sample time")
    require(sample?.session?.resetsAt == ISO8601DateFormatter().date(from:"2026-11-06T12:00:00Z"), "explicit reset timezone is respected")
    require(sample?.weekly?.resetsAt == ISO8601DateFormatter().date(from:"2026-11-08T10:00:00Z"), "native weekly date is interpreted within its window")
    let weekly = try OfficialCLIUsageOutput.read("Current week: 20% used",identity:identity,observedAt:now)
    require(weekly?.session == nil && weekly?.weekly?.used == 20, "plans without a five-hour window remain supported")
    let unknownTime = try OfficialCLIUsageOutput.read("Current week: 20% used · resets future-format", identity:identity, observedAt:now)
    require(unknownTime?.weekly?.resetsAt == nil, "unknown reset time is not invented")
    for bad in ["", "Total cost: $3.40", "Used 13%", "Current week (Sonnet only): 25% used"] {
        require(try OfficialCLIUsageOutput.read(bad,identity:identity,observedAt:now) == nil, "unrecognized text is not turned into a fresh allowance")
    }
    for bad in ["Current session: 101% used", "Current week: 20% used\nCurrent week: 30% used", "Login expired · Please run /login\nCurrent week: 20% used", "{\"type\":\"result\",\"is_error\":true,\"result\":\"Current week: 20% used\"}"] {
        do { _ = try OfficialCLIUsageOutput.read(bad,identity:identity,observedAt:now); preconditionFailure("invalid or failed result accepted") } catch { count += 1 }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-output-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"),withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let file=root.appendingPathComponent(".claude.json")
    let original=try JSONSerialization.data(withJSONObject:["oauthAccount":["accountUuid":"fake-account","organizationUuid":"fake-org"]])
    try original.write(to:file)
    let binding=CLIBinding(identity:identity,choice:.defaultLogin,directory:root.appendingPathComponent(".claude"))
    var stages:[String]=[]
    let result=try await AccountUsageQuery.query(home:root,binding:binding,proxy:UsageQueryProxy(host:"127.0.0.1",port:9999),country:"SG",executable:URL(fileURLWithPath:"/fixture/claude"),observe:{stages.append($0)},run:{_,args,_ in
        if args.contains("auth") {
            let report = try JSONSerialization.data(withJSONObject: ["loggedIn":true,"authMethod":"claude.ai","configDirectory":binding.directory.path,"accountId":"fake-account","orgId":"fake-org"])
            return .init(status:0,text:String(decoding:report,as:UTF8.self),timedOut:false)
        }
        return .init(status:0,text:args[2] == "/usr/bin/curl" ? "loc=SG\n" : String(decoding:data,as:UTF8.self),timedOut:false)
    })
    require(result.session?.used == 13 && result.weekly?.used == 46, "query accepts valid native output when the official cache was not written")
    require(try Data(contentsOf:file) == original, "switcher does not write the CLI login or cache file")
    require(stages.last == "nativeOutputRead" && stages.contains("runningOfficialCLI"), "sanitized stage diagnostics identify the actual path without storing raw output")
    do {
        _ = try await AccountUsageQuery.query(home:root,binding:binding,proxy:UsageQueryProxy(host:"127.0.0.1",port:9999),country:"SG",executable:URL(fileURLWithPath:"/fixture/claude"),run:{_,args,_ in
            if args.contains("auth") {
                let report = try JSONSerialization.data(withJSONObject:["loggedIn":true,"authMethod":"api_key","configDirectory":binding.directory.path])
                return .init(status:0,text:String(decoding:report,as:UTF8.self),timedOut:false)
            }
            return .init(status:0,text:args[2] == "/usr/bin/curl" ? "loc=SG\n" : String(decoding:data,as:UTF8.self),timedOut:false)
        })
        preconditionFailure("native text was assigned despite an API authentication report")
    } catch { count += 1 }
    return count
}
