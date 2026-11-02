import Foundation
import AppKit
import SwitcherCore

@MainActor func refreshClosureChecks() async throws -> Int {
    var checks=0
    func require(_ value:Bool,_ detail:String) {precondition(value,detail);checks += 1}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("rc2-refresh-fixture-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let now=Date(),store=Store(demo:true),identity=Store(demo:true).active!.snapshot!.identity
    func cache(at date:Date) throws -> OfficialCLIUsageCache {
        let data=try CLIJSON.encode(["oauthAccount":["accountUuid":identity.accountID!,"organizationUuid":identity.organizationID!,"emailAddress":identity.email!],
            "cachedUsageUtilization":["accountUuid":identity.accountID!,"fetchedAtMs":date.timeIntervalSince1970*1000,
            "utilization":["seven_day":["utilization":49]]]])
        return try OfficialCLIUsageCache.read(data)!
    }
    let old=try cache(at:now.addingTimeInterval(-1200))
    var recoveries=0,bootstraps=0,fetches=0
    let operations=StatusRefreshOperations(recover:{recoveries += 1;return .renewed},gate:{true},bootstrap:{_ in bootstraps += 1},readCache:{old},fetchFresh:{
        fetches += 1;var sample=store.active!.snapshot!;sample.fetchedAt=now;sample.weekly=Window(used:49,resetsAt:nil)
        store.acceptSubscriptionUsageResult(.success(sample),for:store.current,contextUnchanged:true)
    })
    await store.refreshAllStatuses(operations:operations,now:now)
    require(recoveries==1 && fetches==1 && bootstraps==1 && store.lastRefresh==now,"renewed login plus stale cache completes one fresh quota read in the actual footer orchestration")
    require(!store.statusRefreshInProgress && !store.refreshing,"the completed footer releases its operation slot")
    let recent=try cache(at:now.addingTimeInterval(-1))
    var unused=0
    let cachedStore=Store(demo:true)
    cachedStore.profiles[0].snapshot!.fetchedAt=now.addingTimeInterval(-300)
    await cachedStore.refreshAllStatuses(operations:.init(recover:{.notNeeded},gate:{true},bootstrap:{_ in},readCache:{recent},fetchFresh:{unused += 1}),now:now)
    require(unused==0 && cachedStore.lastRefresh==recent.fetchedAt,"a genuinely new account-matched native sample is reused without another request")
    let afterAuthorization=Store(demo:true)
    afterAuthorization.profiles[0].snapshot!.fetchedAt=now.addingTimeInterval(-300)
    let newAfterWait=try cache(at:now.addingTimeInterval(44))
    await afterAuthorization.refreshAllStatuses(operations:.init(recover:{.renewed},gate:{true},bootstrap:{_ in},readCache:{newAfterWait},fetchFresh:{preconditionFailure("just-written native sample must be reused")}),now:now,clock:{now.addingTimeInterval(45)})
    require(afterAuthorization.lastRefresh==newAfterWait.fetchedAt,"freshness uses the post-authorization clock instead of rejecting a sample written after the click began")
    let cancelled=Store(demo:true)
    await cancelled.refreshAllStatuses(operations:.init(recover:{.authorizationRequired},gate:{preconditionFailure("no gate after cancelled authorization")},bootstrap:{_ in preconditionFailure("no second prompt")},readCache:{preconditionFailure("no follow-up after denial")},fetchFresh:{preconditionFailure("no follow-up after denial")}),now:now)
    require(!cancelled.statusRefreshInProgress,"authorization denial ends the entire click without chasing another object")
    let networkHeld=Store(demo:true)
    await networkHeld.refreshAllStatuses(operations:.init(recover:{.notNeeded},gate:{false},bootstrap:{_ in preconditionFailure("unsafe network cannot request credentials")},readCache:{nil},fetchFresh:{preconditionFailure("no request after unknown route")}),now:now)
    require(networkHeld.usageNotice != nil,"network hold preserves quota and explains why no request was sent")
    let limited=Store(demo:true)
    var attempts=0
    let limitedOperations=StatusRefreshOperations(recover:{attempts += 1;return .notNeeded},gate:{true},bootstrap:{_ in},readCache:{nil},fetchFresh:{throw UsageHTTPFailure(code:429,retryAfter:now.addingTimeInterval(900))})
    await limited.refreshAllStatuses(operations:limitedOperations,now:now)
    limited.usageRefreshPolicy.credentialsChanged(profile:limited.current)
    await limited.refreshAllStatuses(operations:limitedOperations,now:now.addingTimeInterval(15))
    require(attempts==1,"manual refresh and a new credential generation cannot bypass server Retry-After")
    var finish:CheckedContinuation<Void,Never>?
    let coalesced=Store(demo:true);var rounds=0
    let delayed=StatusRefreshOperations(recover:{rounds += 1;return .notNeeded},gate:{true},bootstrap:{_ in},readCache:{nil},fetchFresh:{await withCheckedContinuation {finish=$0}})
    let first=Task {@MainActor in await coalesced.refreshAllStatuses(operations:delayed,now:now)}
    while finish==nil {await Task.yield()}
    await coalesced.refreshAllStatuses(operations:delayed,now:now)
    finish!.resume();await first.value
    require(rounds==1 && !coalesced.statusRefreshInProgress,"overlapping footer actions share the in-flight operation instead of starting another authorization round")

    let switchingDuringRefresh=Store(demo:true)
    var gateCompletion:CheckedContinuation<Bool,Never>?
    let heldGate=StatusRefreshOperations(recover:{.notNeeded},gate:{await withCheckedContinuation {gateCompletion=$0}},bootstrap:{_ in},readCache:{nil},fetchFresh:{})
    let heldTask=Task {@MainActor in await switchingDuringRefresh.refreshAllStatuses(operations:heldGate,now:now)}
    while gateCompletion==nil {await Task.yield()}
    await switchingDuringRefresh.switchTo("Business")
    require(switchingDuringRefresh.current=="Personal","a second manual account action cannot start another authorization flow during footer preparation")
    gateCompletion!.resume(returning:true);await heldTask.value

    let home=root.appendingPathComponent("home"),document=home.appendingPathComponent(".claude.json")
    try FileManager.default.createDirectory(at:home.appendingPathComponent(".claude"),withIntermediateDirectories:true)
    try CLIJSON.encode(["oauthAccount":["accountUuid":identity.accountID!,"organizationUuid":identity.organizationID!,"emailAddress":identity.email!]]).write(to:document)
    var credential=try CLIJSON.encode(["claudeAiOauth":["accessToken":"fictional-live","refreshToken":"fictional-refresh","expiresAt":now.addingTimeInterval(3600).timeIntervalSince1970*1000]])
    var backups:[String:Data]=[:]
    let io=NativeCLIStorage(identity:document,marker:home.appendingPathComponent("marker"),credentialFile:home.appendingPathComponent(".claude/.credentials.json"),secretReader:{service,account in service==cliService ? credential : backups[account]},secretWriter:{service,account,value in
        guard service==switcherService else {preconditionFailure("cannot write real native login")};backups[account]=value
    })
    let cold=Store(demo:true);cold.invalidateCLIStatus();var verifications=0
    let coldResult=await cold.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("healthy saved login requires no native helper")},verify:{_ in verifications += 1;return identity},now:now)
    require(coldResult == .notNeeded && cold.cliStatus == .matched && verifications==1,"cold saved login can finish one silent online match without a manual refresh or native CLI")
    cold.usageRefreshPolicy.failed(profile:cold.current,now:now)
    credential=try CLIJSON.encode(["claudeAiOauth":["accessToken":"fictional-rotated","refreshToken":"fictional-next","expiresAt":now.addingTimeInterval(7200).timeIntervalSince1970*1000]])
    let changed=await cold.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("natural rotation is already complete")},verify:{_ in identity},now:now.addingTimeInterval(61))
    require(changed == .renewed && cold.usageCatchUpPending && cold.usageRefreshPolicy.shouldRequest(profile:cold.current,sampledAt:now,resetsAt:[],active:true,trigger:.identityChanged,now:now.addingTimeInterval(61)),"same-account native rotation schedules quota catch-up and clears the repaired ordinary failure")
    require(try cold.verifiedQuietCLILogin(matching:identity,io:io)?.1 == "fictional-rotated","quota can use the exact verified CLI generation when the desktop token has not caught up")
    let staleProof=cold.currentCLIObservedLogin!
    cold.currentCLIObservedLogin=(staleProof.name,staleProof.identity,"different-generation")
    require(try cold.verifiedQuietCLILogin(matching:identity,io:io)==nil,"a remembered identity without the exact credential-generation proof cannot supply quota")
    cold.currentCLIObservedLogin=staleProof
    let retrying=Store(demo:true)
    _ = await retrying.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("healthy")},verify:{_ in identity},now:now)
    credential=try CLIJSON.encode(["claudeAiOauth":["accessToken":"fictional-rotated-again","refreshToken":"fictional-next-again","expiresAt":now.addingTimeInterval(7200).timeIntervalSince1970*1000]])
    let held=await retrying.recoverCurrentCLI(io:io,context:{true},gate:{false},native:{preconditionFailure("already rotated")},verify:{_ in identity},now:now.addingTimeInterval(61))
    let continued=await retrying.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("never rotate twice")},verify:{_ in identity},now:now.addingTimeInterval(400))
    require(held == .retryLater && continued == .renewed,"a temporary network failure after external rotation retains its pending verification and backup")
    let coldFailure=Store(demo:true);coldFailure.invalidateCLIStatus()
    _ = await coldFailure.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("no native")},verify:{_ in throw URLError(.timedOut)},now:now)
    _ = await coldFailure.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("no native")},verify:{_ in identity},now:now.addingTimeInterval(61))
    require(coldFailure.cliStatus == .matched,"cold online verification can recover from a transient failure without waiting for expiry or a manual click")
    let backupDeferred=Store(demo:true)
    let blockedBackupIO=NativeCLIStorage(identity:document,marker:home.appendingPathComponent("marker"),credentialFile:home.appendingPathComponent(".claude/.credentials.json"),secretReader:{service,account in service==cliService ? credential : backups[account]},secretWriter:{_,_,_ in throw CLIInteractionRequired()})
    let backupResult=await backupDeferred.recoverCurrentCLI(manual:true,requestNativeCheck:true,io:blockedBackupIO,context:{true},gate:{true},native:{
        credential=try! CLIJSON.encode(["claudeAiOauth":["accessToken":"fictional-verified-backup-pending","refreshToken":"fictional-next","expiresAt":now.addingTimeInterval(7200).timeIntervalSince1970*1000]])
        return .completed
    },verify:{_ in identity},now:now)
    require(backupResult == .backupPending && backupDeferred.cliStatus == .matched,"a denied backup write does not misrepresent a verified usable login as a login failure")
    require(try backupDeferred.verifiedQuietCLILogin(matching:identity,io:blockedBackupIO)?.1 == "fictional-verified-backup-pending","quota may finish with the verified current credential even while only the backup needs permission")
    var locked=true
    let lockIO=NativeCLIStorage(identity:document,marker:home.appendingPathComponent("marker"),credentialFile:home.appendingPathComponent(".claude/.credentials.json"),secretReader:{service,account in
        if locked {throw CLIInteractionRequired()};return service==cliService ? credential : backups[account]
    },secretWriter:{_,_,_ in preconditionFailure("healthy login needs no credential write")})
    let unlockedStore=Store(demo:true)
    _ = await unlockedStore.recoverCurrentCLI(io:lockIO,context:{true},gate:{true},native:{preconditionFailure("no system UI")},verify:{_ in identity},now:now)
    locked=false
    let unlocked=await unlockedStore.recoverCurrentCLI(io:lockIO,context:{true},gate:{true},native:{preconditionFailure("unlock does not authorize a native helper")},verify:{_ in identity},now:now.addingTimeInterval(61))
    require(unlocked == .notNeeded && unlockedStore.cliStatus == .matched && unlockedStore.currentCLIRecoveryOutcome==nil,"a formerly locked but now silently readable healthy login clears a stale authorization reminder without another manual click")
    let rejected=Store(demo:true);var confirmations=0
    let rejection=await rejected.recoverCurrentCLI(manual:true,io:io,context:{true},gate:{true},native:{confirmations += 1;return .loginRequired},verify:{_ in throw ProfileHTTPFailure(code:401)},now:now)
    require(rejection == .needsLogin && confirmations==1,"a future local expiry cannot suppress explicit native confirmation after an online rejection")
    let confirmedAgain=await rejected.recoverCurrentCLI(manual:true,requestNativeCheck:true,io:io,context:{true},gate:{true},native:{confirmations += 1;return .completed},verify:{_ in identity},now:now.addingTimeInterval(1))
    require(confirmedAgain == .renewed && rejected.cliStatus == .matched && confirmations==2,"one new native success plus an online identity check clears an old rejection even when the token bytes did not change")
    let rejectedBackground=Store(demo:true);rejectedBackground.invalidateCLIStatus()
    let backgroundRejection=await rejectedBackground.recoverCurrentCLI(io:io,context:{true},gate:{true},native:{preconditionFailure("no background system prompt")},verify:{_ in throw ProfileHTTPFailure(code:403)},now:now)
    require(backgroundRejection == .authorizationRequired && !rejectedBackground.currentCLIRecoveryDidRunNative,"an online rejection requests user confirmation without pretending HTTP 403 permanently revokes the login")
    var asks:[Bool]=[]
    let budget=NativeCLIStorage(identity:document,marker:home.appendingPathComponent("marker"),credentialFile:home.appendingPathComponent(".claude/no-file"),interactionReader:{_,_,allow in asks.append(allow);return credential})
    _=try budget.readCredentials();_=try budget.readCredentials();_=try budget.readBackup("Personal");_=try budget.readBackup("Personal")
    require(budget.readSummary.reduce(0,{$0+$1.reads})==4 && budget.readSummary.reduce(0,{$0+$1.interactiveRequestsAllowed})==2,"diagnostics count read permissions without claiming a count of actual system authorization dialogs")
    let encodedDiagnostics=String(decoding:try JSONEncoder().encode(store.lastRefreshDiagnostics!),as:UTF8.self)
    require(!encodedDiagnostics.contains("accessToken") && !encodedDiagnostics.contains(identity.email!) && !encodedDiagnostics.contains("fictional-live"),"manual diagnostics contain action counts, not token material or account identity")
    require(asks == [true,false,true,false],"final credential comparisons remain fresh but cannot request UI repeatedly for one object in one operation")

    let fakeCLI=home.appendingPathComponent(".local/bin/claude")
    try FileManager.default.createDirectory(at:fakeCLI.deletingLastPathComponent(),withIntermediateDirectories:true)
    let hang="#\u{21}/usr/bin/python3\nimport signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(30)\n"
    try Data(hang.utf8).write(to:fakeCLI);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:fakeCLI.path)
    let start=Date();var bounded=false
    do {_=try await CLIStatusReader.read(home:home,timeoutSeconds:0.1,graceSeconds:0.1)} catch {bounded=true}
    require(bounded && Date().timeIntervalSince(start)<5,"a status helper that ignores soft termination cannot trap the footer forever")
    let usageStart=Date();bounded=false
    do {_=try await OfficialCLIUsageReader.read(home:home,manual:true,environment:[:],timeoutSeconds:0.1,graceSeconds:0.1)} catch {bounded=true}
    require(bounded && Date().timeIntervalSince(usageStart)<5,"the old usage adapter has the same hard timeout without affecting existing tasks")
    require(OfficialCLICurrentRenewal.environment(home:home,inherited:["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1"])["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]==nil,"actual usage/recovery helpers do not inherit cache-only traffic suppression")
    return checks
}
