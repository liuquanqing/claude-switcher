import Foundation
import AppKit
import Security
import LocalAuthentication
import SwitcherCore

@MainActor private final class CurrentFixtureIO: CLICredentialIO {
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

@MainActor func currentCLIRecoveryChecks() async throws -> Int {
    var checks=0
    func require(_ condition: Bool, _ message: String) { precondition(condition,message);checks += 1 }
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("current-cli-fixture-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    defer {try? FileManager.default.removeItem(at:root)}
    let home=root.appendingPathComponent("home"),cli=home.appendingPathComponent(".local/bin/claude")
    try FileManager.default.createDirectory(at:cli.deletingLastPathComponent(),withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:home.appendingPathComponent(".claude"),withIntermediateDirectories:true)
    let code = #"""
    #!/bin/sh
    if [ "$1" = "--version" ]; then printf '2.1.314 (Claude Code)\n'; exit 0; fi
    [ "$1" = "-p" ] && [ "$2" = "/usage" ] || exit 90
    [ -z "$CLAUDE_CONFIG_DIR" ] && [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ -z "$CLAUDE_CODE_OAUTH_REFRESH_TOKEN" ] || exit 91
    mode=$(/bin/cat "$HOME/scenario")
    printf 'called\n' >> "$HOME/calls"
    case "$mode" in
      success) /bin/cp "$HOME/new.json" "$HOME/.claude/.credentials.json"; printf 'Usage read complete\n'; exit 0 ;;
      login) printf 'Login expired · Please run /login\n' >&2; exit 1 ;;
      authorize) printf 'User interaction is not allowed\n' >&2; exit 1 ;;
      network) printf 'ECONNRESET request failed\n' >&2; exit 1 ;;
      unsupported) printf 'unknown option --permission-prompts\n' >&2; exit 1 ;;
      huge) exec /usr/bin/python3 -c 'import sys;sys.stdout.write("x"*300000+"\nLogin expired · Please run /login\n");sys.exit(1)' ;;
      timeout) exec /usr/bin/python3 -c 'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(10)' ;;
    esac
    exit 92
    """#
    try Data(code.utf8).write(to:cli)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
    let inherited=["ANTHROPIC_API_KEY":"fixture-key", "CLAUDE_CONFIG_DIR":"/fixture/other", "CLAUDE_CODE_OAUTH_TOKEN":"fixture-token",
                   "CLAUDE_CODE_OAUTH_REFRESH_TOKEN":"fixture-refresh", "CLAUDE_CODE_SIMPLE":"1", "HTTPS_PROXY":"http://127.0.0.1:19999"]
    let env=OfficialCLICurrentRenewal.environment(home:home,inherited:inherited)
    require(env["HOME"]==home.path && env["CLAUDE_CONFIG_DIR"]==nil,"current renewal must use the default native directory, not clone the current refresh token")
    require(env["ANTHROPIC_API_KEY"]==nil && env["CLAUDE_CODE_OAUTH_TOKEN"]==nil && env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"]==nil && env["CLAUDE_CODE_SIMPLE"]==nil,
            "ambient API and token overrides, and bare mode, cannot hijack native current-account recovery")
    require(env["HTTPS_PROXY"]==inherited["HTTPS_PROXY"],"the CLI's proxy environment must survive without changing system routing")
    require(OfficialCLICurrentRenewal.supportsVersion("2.1.314 (Claude Code)") && !OfficialCLICurrentRenewal.supportsVersion("2.1.210")
            && !OfficialCLICurrentRenewal.supportsVersion("unknown"),"native automatic recovery requires a compatible CLI generation with coordinated credential renewal")
    let outcomes:[(String,CLINativeRenewalOutcome)]=[("login",.loginRequired),("authorize",.authorizationRequired),("network",.temporaryFailure),("unsupported",.unsupported),("huge",.loginRequired)]
    for (scenario,expected) in outcomes {
        try scenario.write(to:home.appendingPathComponent("scenario"),atomically:true,encoding:.utf8)
        let result=try await OfficialCLICurrentRenewal.run(home:home,executable:cli,inherited:inherited,timeoutSeconds:10)
        require(result==expected,"bounded native output must classify the fixture without persisting or displaying secret text")
    }
    try "timeout".write(to:home.appendingPathComponent("scenario"),atomically:true,encoding:.utf8)
    let start=Date()
    let timedOut=try await OfficialCLICurrentRenewal.run(home:home,executable:cli,inherited:[:],timeoutSeconds:0.1,graceSeconds:0.1)
    require(timedOut == .timedOut && Date().timeIntervalSince(start)<5,"a stuck newly spawned CLI is bounded without waiting on existing terminal tasks")
    let fixtureNow=Date(timeIntervalSince1970:1_800_000_000)
    let store=Store(demo:true);let identity=store.active!.snapshot!.identity
    store.setBackgroundCLIRenewalPermission(true)
    func data(token:String,seconds:Double) throws -> Data {
        try CLIJSON.encode(["claudeAiOauth":["accessToken":token,"refreshToken":"fake-refresh-"+token,
            "expiresAt":fixtureNow.addingTimeInterval(seconds).timeIntervalSince1970*1000]])
    }
    let old=try data(token:"fixture-old",seconds:-60),new=try data(token:"fixture-new",seconds:3600)
    try old.write(to:home.appendingPathComponent(".claude/.credentials.json"))
    try new.write(to:home.appendingPathComponent("new.json"))
    try CLIJSON.encode(["oauthAccount":["accountUuid":identity.accountID!,"organizationUuid":identity.organizationID!,"emailAddress":identity.email!]])
        .write(to:home.appendingPathComponent(".claude.json"))
    let io=CurrentFixtureIO(home:home);let guardBefore=store.protection.lastDecision;let countBefore=store.profiles.count
    try "success".write(to:home.appendingPathComponent("scenario"),atomically:true,encoding:.utf8)
    let result=await store.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{
        try await OfficialCLICurrentRenewal.run(home:home,executable:cli,inherited:[:])
    },verify:{_ in identity},now:fixtureNow)
    require(result == .renewed && store.cliStatus == .matched && store.cliStatusCheckedAt==fixtureNow,"candidate Store and fake native CLI complete current-account recovery together")
    require(io.liveWrites==0 && store.current=="Personal" && store.profiles.count==countBefore && store.protection.lastDecision==guardBefore,
            "Store never writes live credentials, moves accounts, changes guard policy or touches sessions")
    require(try CLIBackup(data:io.backups["Personal"]!).trustedIdentity()==identity,"only the new verified current login is saved to our backup")
    let demoRefusal=await store.recoverCurrentCLI(manual:true)
    require(demoRefusal == .unsupported,"demo mode refuses all production recovery adapters")
    let consentStore=Store(demo:true)
    require(consentStore.allowBackgroundCLIRenewal==false,"native background system-authorization consent is off until explicitly chosen")
    try old.write(to:home.appendingPathComponent(".claude/.credentials.json"))
    let noConsent=await consentStore.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("no consent must mean no native process")},verify:{_ in identity},now:fixtureNow)
    require(noConsent == .authorizationRequired && !consentStore.currentCLIRecoveryDidRunNative,
            "an expired login cannot start even a fixture native process without background consent")
    consentStore.setBackgroundCLIRenewalPermission(true)
    require(consentStore.allowBackgroundCLIRenewal,"the candidate supports explicitly enabling native automatic recovery without mutating real defaults in demo mode")
    let failedStore=Store(demo:true)
    failedStore.setBackgroundCLIRenewalPermission(true)
    try old.write(to:home.appendingPathComponent(".claude/.credentials.json"))
    let failed=await failedStore.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{.loginRequired},verify:{_ in identity},now:fixtureNow)
    require(failed == .needsLogin && failedStore.cliStatus == .needsLogin && failedStore.banner?.contains("/login")==true,
            "an explicit native login failure produces a clear official /login instruction")
    let failedChecked=failedStore.cliStatusCheckedAt
    var metadata=CLIStatusPresentation();metadata.identity=identity;metadata.profile="Personal";metadata.metadataOnly=true
    await failedStore.updateCLIStatus { metadata }
    require(failedStore.cliStatus == .needsLogin && failedStore.cliStatusCheckedAt==failedChecked,
            "the next local metadata tick must not hide a confirmed login failure")
    failedStore.banner=nil
    let paused=await failedStore.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("no automatic retry loop")},verify:{_ in identity},now:fixtureNow.addingTimeInterval(600))
    require(paused == .needsLogin && failedStore.banner==nil,"dismissing the login notice does not make it reappear on every automatic check")
    try new.write(to:home.appendingPathComponent(".claude/.credentials.json"))
    let healthy=await failedStore.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("new native login must win")},verify:{_ in identity},now:fixtureNow.addingTimeInterval(661))
    require(healthy == .renewed && !failedStore.cliRecoveryNeedsAttention,"a real new login generation clears the paused failure and backs up that newer native login without restoring an old one")
    let coldStore=Store(demo:true)
    coldStore.profiles[0].snapshot=nil
    let coldResult=await coldStore.recoverCurrentCLI(manual:true,io:io,context:{true},gate:{true},native:{preconditionFailure("bootstrap first")},verify:{_ in identity},now:fixtureNow)
    require(coldResult == .notNeeded,"current recovery must not intercept an explicit first-install desktop identity bootstrap")
    let blockedReadback=Store(demo:true)
    blockedReadback.setBackgroundCLIRenewalPermission(true)
    try old.write(to:home.appendingPathComponent(".claude/.credentials.json"))
    let authorizedLater=await blockedReadback.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{
        try new.write(to:home.appendingPathComponent(".claude/.credentials.json"));io.denyCredentialRead=true;return .completed
    },verify:{_ in identity},now:fixtureNow)
    require(authorizedLater == .authorizationRequired && blockedReadback.currentCLIBackupPending != nil,
            "authorization blocking readback after native rotation keeps a pending backup, never spends the refresh token again")
    io.denyCredentialRead=false
    let finishedReadback=await blockedReadback.recoverCurrentCLI(manual:true,io:io,context:{true},gate:{true},native:{preconditionFailure("renewal already saved")},verify:{_ in identity},now:fixtureNow)
    require(finishedReadback == .renewed && blockedReadback.currentCLIBackupPending==nil,"explicit authorization can finish validation and backup without another native renewal")
    let unsupportedStore=Store(demo:true);var nativeChecks=0
    let unsupportedResult=await unsupportedStore.recoverCurrentCLI(manual:true,requestNativeCheck:true,io:io,context:{true},gate:{true},native:{nativeChecks += 1;return .unsupported},verify:{_ in identity},now:fixtureNow)
    require(unsupportedResult == .unsupported && unsupportedStore.currentCLIBackupPending==nil,
            "an unsupported native command with unchanged credentials cannot become a pending successful renewal")
    let supportedAgain=await unsupportedStore.recoverCurrentCLI(manual:true,requestNativeCheck:true,io:io,context:{true},gate:{true},native:{nativeChecks += 1;return .completed},verify:{_ in identity},now:fixtureNow)
    require(supportedAgain == .notNeeded && nativeChecks==2 && unsupportedStore.banner==nil,
            "a later explicit retry rechecks the native command and clears its obsolete unsupported notice")
    var wrote=false
    try KeychainWriteAccess.backup(service:switcherService,account:"fixture",data:Data("fake".utf8),allowInteraction:false,update:{query,_ in
        let q=query as NSDictionary
        require((q[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed==true,"automatic backup writes forbid authorization UI")
        return errSecItemNotFound
    },add:{query,_ in
        let q=query as NSDictionary
        require((q[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed==true,"automatic backup insertion also forbids authorization UI")
        wrote=true;return errSecSuccess
    })
    require(wrote,"the isolated keychain adapter writes only the fixture's own backup")
    var denied=false
    do {try KeychainWriteAccess.backup(service:"Claude Code-credentials",account:"fixture",data:Data(),allowInteraction:false,update:{_,_ in preconditionFailure("never write native OAuth")},add:{_,_ in preconditionFailure("never add native OAuth")})}
    catch {denied=true}
    require(denied,"current recovery's keychain writer refuses every native credential service")
    require(OfficialCLICurrentRenewal.classify(status:1,text:"401 from a provider") == .temporaryFailure,
            "HTTP 401 alone is not proof that a refresh token was revoked")
    failedStore.publishCurrentCLIRecovery(.needsLogin,profile:"Personal",identity:identity,now:fixtureNow)
    _ = failedStore.applyLocalAccountObservation(LocalAccountObservation(desktopAccountID:"fixture-other-account",fingerprint:"fixture-other"))
    require(failedStore.currentCLIRecoveryOutcome==nil && failedStore.banner==nil && failedStore.cliStatus == .unverified,
            "switching the real desktop identity does not carry the previous account's recovery failure into the new one")
    let networkHeldStore=Store(demo:true)
    let readsBefore=io.credentialReadCount
    let held=await networkHeldStore.recoverCurrentCLI(manual:true,requestNativeCheck:true,io:io,context:{true},gate:{false},
        native:{preconditionFailure("unsafe route cannot start official CLI")},verify:{_ in preconditionFailure("unsafe route cannot query identity")},now:fixtureNow)
    require(held == .retryLater && io.credentialReadCount==readsBefore && !networkHeldStore.currentCLIRecoveryRunning && networkHeldStore.busy==nil,
            "network rejection precedes every interactive credential read and releases the operation slot")
    require(networkHeldStore.banner?.contains("网络检查未通过")==true && networkHeldStore.cliStatus != .needsLogin,
            "unsafe network is explained as a network hold, not a revoked login")
    let changedNetworkStore=Store(demo:true)
    try old.write(to:home.appendingPathComponent(".claude/.credentials.json"))
    var networkRounds=0
    let afterAuthorization=await changedNetworkStore.recoverCurrentCLI(manual:true,io:io,context:{true},gate:{networkRounds += 1;return networkRounds==1},
        native:{preconditionFailure("network lost during authorization")},verify:{_ in preconditionFailure("no identity query after route loss")},now:fixtureNow)
    require(afterAuthorization == .retryLater && networkRounds==2 && !changedNetworkStore.currentCLIRecoveryDidRunNative,
            "a successful pre-authorization check is never reused after authorization has had time to finish")
    require(OfficialCLICurrentRenewal.guaranteesNoSystemPrompt == false,
            "the current official adapter does not falsely promise control over macOS authorization UI")
    let changedBeforeAuth=Store(demo:true)
    let countBeforeChange=io.credentialReadCount
    let changed=await changedBeforeAuth.recoverCurrentCLI(manual:true,io:io,context:{false},gate:{true},
        native:{preconditionFailure("changed owner")},verify:{_ in identity},now:fixtureNow)
    require(changed == .contextChanged && io.credentialReadCount==countBeforeChange && changedBeforeAuth.busy==nil && changedBeforeAuth.banner==nil,
            "an account change during the initial network check is not mislabeled as a network failure and cannot request authorization")
    return checks
}
