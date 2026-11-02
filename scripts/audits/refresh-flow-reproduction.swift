import Foundation
import AppKit
import Security
import LocalAuthentication
import SwitcherCore
@MainActor private final class AuditFixtureIO: CLICredentialIO {
    let home: URL
    var backups: [String:Data] = [:]
    var liveWrites = 0
    var denyCredentialRead = false
    var credentialReadCount = 0
    init(home: URL) { self.home = home }
    func readCredentials() throws -> Data? {
        credentialReadCount += 1
        if denyCredentialRead { throw CLIInteractionRequired() }
        return try Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))
    }
    func readIdentityDocument() throws -> Data? { try Data(contentsOf: home.appendingPathComponent(".claude.json")) }
    func writeCredentials(_ data: Data?) throws { liveWrites += 1; throw SafetyError("fixture must not write live credentials") }
    func writeIdentityDocument(_ data: Data?) throws { liveWrites += 1; throw SafetyError("fixture must not write identity") }
    func readBackup(_ profile: String) throws -> Data? { backups[profile] }
    func writeBackup(_ profile: String, data: Data) throws { backups[profile] = data }
    func readMarker() throws -> String? { "Personal" }
    func writeMarker(_ value: String?) throws { liveWrites += 1; throw SafetyError("fixture must not write marker") }
}


@main struct Audit {
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("refresh-audit-fixture-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:root) }
  let home=root.appendingPathComponent("home"),cli=home.appendingPathComponent(".local/bin/claude")
  try FileManager.default.createDirectory(at:cli.deletingLastPathComponent(),withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:home.appendingPathComponent(".claude"),withIntermediateDirectories:true)
  let store=Store(demo:true), now=Date(), identity=Store(demo:true).active!.snapshot!.identity
  let document=home.appendingPathComponent(".claude.json"),credential=home.appendingPathComponent(".claude/.credentials.json")
  let staleAt=now.addingTimeInterval(-1200)
  let metadata:[String:Any] = ["accountUuid":identity.accountID!,"organizationUuid":identity.organizationID!,"emailAddress":identity.email!]
  try CLIJSON.encode(["oauthAccount":metadata,"cachedUsageUtilization":["accountUuid":identity.accountID!,"fetchedAtMs":staleAt.timeIntervalSince1970*1000,"utilization":["five_hour":["utilization":28],"seven_day":["utilization":61]]]]) .write(to:document)
  func credentials(_ label:String,_ offset:Double) throws -> Data {
    try CLIJSON.encode(["claudeAiOauth":["accessToken":"fictional-"+label,"refreshToken":"fictional-refresh-"+label,"expiresAt":now.addingTimeInterval(offset).timeIntervalSince1970*1000]])
  }
  try credentials("healthy",3600).write(to:credential)
  let io=AuditFixtureIO(home:home)
  store.invalidateCLIStatus()
  await store.updateCLIStatus { CLIStatusPresentation(status:.unverified,profile:"Personal",email:identity.email,identity:identity,metadataOnly:true) }
  var nativeCalls=0
  let healthy=await store.recoverCurrentCLI(io:io,context:{true},gate:{preconditionFailure("healthy login requires no request")},native:{nativeCalls += 1;return .completed},verify:{_ in identity},now:now)
  precondition(healthy == .notNeeded && nativeCalls==0 && store.cliStatus == .unverified)
  let before=LocalAccountObservation.read(desktop:root.appendingPathComponent("missing-desktop.json"),cli:document,profile:"Personal",scope:.subscription)
  try credentials("rotated",3600).write(to:credential)
  let after=LocalAccountObservation.read(desktop:root.appendingPathComponent("missing-desktop.json"),cli:document,profile:"Personal",scope:.subscription)
  precondition(before==after)
  var policy=UsageRefreshPolicy();policy.began(profile:"Personal",now:now);policy.failed(profile:"Personal",now:now)
  let waits=policy.shouldRequest(profile:"Personal",sampledAt:staleAt,resetsAt:[],active:true,trigger:.identityChanged,now:now.addingTimeInterval(61))
  precondition(!waits)
  let recoveryStore=Store(demo:true)
  try credentials("expired",-60).write(to:credential)
  try credentials("recovered",3600).write(to:home.appendingPathComponent("new.json"))
  let program = #"""
  #!/bin/sh
  if [ "$1" = "--version" ]; then echo '2.1.314 (Claude Code)'; exit 0; fi
  [ "$1" = -p ] && [ "$2" = /usage ] || exit 90
  /bin/cp "$HOME/new.json" "$HOME/.claude/.credentials.json"
  echo 'Usage read complete'
  """#
  try Data(program.utf8).write(to:cli)
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
  let result=await recoveryStore.recoverCurrentCLI(manual:true,requestNativeCheck:true,io:io,context:{true},gate:{true},native:{try await OfficialCLICurrentRenewal.run(home:home,executable:cli,inherited:[:])},verify:{_ in identity},now:now)
  precondition(result == .renewed && recoveryStore.currentCLIRecoveryDidRunNative && recoveryStore.cliStatus == .matched)
  let cache=try await OfficialCLIUsageReader.read(home:home,manual:false,now:now,environment:[:])
  precondition(cache != nil && now.timeIntervalSince(cache!.fetchedAt)>1199)
  let findings:[[String:Any]]=[
   ["id":"CLI-COLD-STATUS","observed":"Healthy saved identity remains unverified after background metadata and recovery","nativeCalls":nativeCalls],
   ["id":"SAME-ACCOUNT-ROTATION","credentialFileChanged":true,"localIdentityFingerprintChanged":before != after],
   ["id":"LOGIN-COOLDOWN","identityChangeRequestedAtSeconds":61,"quotaRequestAllowed":waits,"ordinaryFailureBackoffSeconds":300],
   ["id":"RECOVERY-STALE-USAGE","nativeRecovery":"renewed","cliDisplay":"matched","cacheReadAgeSeconds":now.timeIntervalSince(cache!.fetchedAt),"nativeUsageCacheWrittenByFixture":false]
  ]
  let report:[String:Any] = ["scope":"component reproduction plus source control-flow review; not end-to-end live acceptance","fictionalDataOnly":true,"realKeychainRead":false,"realLoginOrGuardOperation":false,"reproducedFindings":findings]
  let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
  print(String(decoding:data,as:UTF8.self))
 }
}
