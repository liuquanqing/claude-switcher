import XCTest
@testable import SwitcherCore

@MainActor final class CLICurrentRecoveryTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let a = CLIIdentity(accountID: "current-a", organizationID: "org-a", email: "a@example.test")
    let b = CLIIdentity(accountID: "current-b", organizationID: "org-b", email: "b@example.test")
    func login(_ identity: CLIIdentity, token: String, seconds: Double, refresh: Bool = true) throws -> CLIOwnedLogin {
        CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken":token,"refreshToken":refresh ? "fake-refresh-"+token : "",
            "expiresAt":date.addingTimeInterval(seconds).timeIntervalSince1970*1000]),
            metadata:try CLIJSON.encode(["accountUuid":identity.accountID!,"organizationUuid":identity.organizationID!,"emailAddress":identity.email!]))
    }
    func set(_ login: CLIOwnedLogin, in io: RecoveryMemoryIO) throws {
        io.credentials = try CLIJSON.replacing(nil,key:"claudeAiOauth",with:login.oauth)
        io.document = try CLIJSON.replacing(nil,key:"oauthAccount",with:login.metadata)
    }
    func fixture(seconds: Double = -60, refresh: Bool = true) throws -> RecoveryMemoryIO {
        let io = RecoveryMemoryIO();try set(login(a,token:"old",seconds:seconds,refresh:refresh),in:io)
        return io
    }
    func recover(_ io: RecoveryMemoryIO, current: @escaping () throws -> Bool = { true },
                 gate: @escaping () async -> Bool = { true },
                 native: @escaping () async throws -> CLINativeRenewalOutcome,
                 verify: ((String) async throws -> CLIIdentity)? = nil) async throws -> CLICurrentRecoveryOutcome {
        try await CLICurrentRecovery.run(target:.init(name:"A",identity:a),io:io,now:{self.date},
            contextIsCurrent:current,gate:gate,native:native,verify:verify ?? {_ in self.a})
    }
    func testHealthyDefaultDoesNotLaunchCLIOrWrite() async throws {
        let io = try fixture(seconds:3600)
        let result = try await recover(io,native:{XCTFail("healthy login");return .completed})
        XCTAssertEqual(result,.notNeeded);XCTAssertEqual(io.liveWrites,0);XCTAssertTrue(io.backups.isEmpty)
    }
    func testExpiredCurrentUsesOfficialCLIAndBacksUpOnlyVerifiedNewLogin() async throws {
        let io = try fixture(), newer = try login(a,token:"new",seconds:3600), oldMarker = io.marker
        var calls = 0
        let result = try await recover(io,native:{calls += 1;try self.set(newer,in:io);return .completed})
        XCTAssertEqual(result,.renewed);XCTAssertEqual(calls,1)
        XCTAssertEqual(try CLIOwnedLogin(credentials:io.credentials,identityDocument:io.document),newer)
        XCTAssertEqual(try CLIBackup(data:io.backups["A"]!).trustedIdentity(),a)
        XCTAssertEqual(io.liveWrites,0);XCTAssertEqual(io.marker,oldMarker)
    }
    func testNearExpiryIsEligibleButUnchangedUsableLoginIsNotInventedRenewal() async throws {
        let io = try fixture(seconds:120);var calls = 0
        let result = try await recover(io,native:{calls += 1;return .completed})
        XCTAssertEqual(result,.notNeeded);XCTAssertEqual(calls,1);XCTAssertTrue(io.backups.isEmpty)
    }
    func testNoRefreshSecretClearlyRequiresLoginWithoutRestoringOldBackup() async throws {
        let io = try fixture(refresh:false)
        io.backups["A"] = try CLIBackup.verifiedData(login:login(a,token:"parked",seconds:3600),identity:a,now:date)
        let credentials=io.credentials,backup=io.backups
        let result = try await recover(io,native:{XCTFail("no refresh");return .completed})
        XCTAssertEqual(result,.needsLogin);XCTAssertEqual(io.credentials,credentials);XCTAssertEqual(io.backups,backup)
    }
    func testNetworkUnknownNeverStartsNativeRenewal() async throws {
        let io = try fixture()
        let result=try await recover(io,gate:{false},native:{XCTFail("network gate");return .completed})
        XCTAssertEqual(result,.retryLater);XCTAssertEqual(io.liveWrites,0)
    }
    func testNativeFailuresDoNotAllMeanLoginRevoked() async throws {
        for (native,expected) in [(CLINativeRenewalOutcome.temporaryFailure,CLICurrentRecoveryOutcome.retryLater),(.timedOut,.retryLater),
                                  (.authorizationRequired,.authorizationRequired),(.unsupported,.unsupported),(.loginRequired,.needsLogin)] {
            let io = try fixture(),before=io.credentials
            let result=try await recover(io,native:{native})
            XCTAssertEqual(result,expected);XCTAssertEqual(io.credentials,before);XCTAssertTrue(io.backups.isEmpty)
        }
    }
    func testChangedAccountBeforeStartNeverRenews() async throws {
        let io=try fixture();try set(login(b,token:"b",seconds:-60),in:io)
        let result=try await recover(io,native:{XCTFail("wrong current account");return .completed})
        XCTAssertEqual(result,.contextChanged);XCTAssertEqual(io.liveWrites,0)
    }
    func testAnotherCLIAlreadyRenewedDuringGateWinsWithoutSecondRefresh() async throws {
        let io=try fixture(),newer=try login(a,token:"external",seconds:3600);var checks=0
        let result=try await recover(io,gate:{
            checks += 1;if checks==1 {try! self.set(newer,in:io)};return true
        },native:{XCTFail("newer native login");return .completed})
        XCTAssertEqual(result,.renewed);XCTAssertEqual(try CLIBackup(data:io.backups["A"]!).login,newer)
    }
    func testRealAccountSwitchDuringNativeRunDoesNotSaveOldAccountBackup() async throws {
        let io=try fixture()
        let result=try await recover(io,native:{try self.set(self.login(self.b,token:"new-b",seconds:3600),in:io);return .completed})
        XCTAssertEqual(result,.contextChanged);XCTAssertTrue(io.backups.isEmpty);XCTAssertEqual(try CLIIdentity.metadata(CLIJSON.field(io.document,key:"oauthAccount")),b)
    }
    func testRotationSavedBeforeTimeoutIsRetainedAndVerified() async throws {
        let io=try fixture(),newer=try login(a,token:"rotated",seconds:3600)
        let result=try await recover(io,native:{try self.set(newer,in:io);return .timedOut})
        XCTAssertEqual(result,.renewed);XCTAssertEqual(try CLIBackup(data:io.backups["A"]!).login,newer)
    }
    func testBackupFailureDoesNotRollBackRenewedNativeCredential() async throws {
        let io=try fixture(),newer=try login(a,token:"rotated",seconds:3600);io.failWrite=true
        let result=try await recover(io,native:{try self.set(newer,in:io);return .completed})
        XCTAssertEqual(result,.backupPending);XCTAssertEqual(try CLIOwnedLogin(credentials:io.credentials,identityDocument:io.document),newer)
        XCTAssertEqual(io.liveWrites,0)
    }
    func testBadReadbackAndWrongBackupOwnerDoNotLoseCurrentLogin() async throws {
        for corrupt in [false,true] {
            let io=try fixture(),newer=try login(a,token:"new",seconds:3600)
            if corrupt {io.corruptReadback=true}
            else {io.backups["A"]=try CLIBackup.verifiedData(login:login(b,token:"other",seconds:3600),identity:b,now:date)}
            let old=io.backups["A"]
            let result=try await recover(io,native:{try self.set(newer,in:io);return .completed})
            XCTAssertEqual(result,.backupPending);XCTAssertEqual(try CLIOwnedLogin(credentials:io.credentials,identityDocument:io.document),newer)
            if !corrupt {XCTAssertEqual(io.backups["A"],old)}
        }
    }
    func testWrongRemoteOrganizationNeverBacksUp() async throws {
        let io=try fixture()
        let result=try await recover(io,native:{try self.set(self.login(self.a,token:"new",seconds:3600),in:io);return .completed},verify:{_ in self.b})
        XCTAssertEqual(result,.contextChanged);XCTAssertTrue(io.backups.isEmpty)
    }
    func testRemoteFailureKeepsRenewedDefaultForLaterValidation() async throws {
        let io=try fixture(),newer=try login(a,token:"new",seconds:3600)
        let result=try await recover(io,native:{try self.set(newer,in:io);return .completed},verify:{_ in throw SafetyError("fixture network")})
        XCTAssertEqual(result,.verificationPending);XCTAssertEqual(try CLIOwnedLogin(credentials:io.credentials,identityDocument:io.document),newer)
        XCTAssertTrue(io.backups.isEmpty)
    }
    func testContextAndTokenChangesDuringVerificationRejectCommit() async throws {
        for changeToken in [false,true] {
            let io=try fixture();var current=true
            let result=try await recover(io,current:{current},native:{try self.set(self.login(self.a,token:"first",seconds:3600),in:io);return .completed},verify:{_ in
                if changeToken {try self.set(self.login(self.a,token:"second",seconds:3600),in:io)} else {current=false}
                return self.a
            })
            XCTAssertEqual(result,.contextChanged);XCTAssertTrue(io.backups.isEmpty);XCTAssertEqual(io.liveWrites,0)
        }
    }
    func testPolicyPausesLoginAndAuthorizationFailuresUntilLoginChangesOrExplicitRetry() {
        var policy=CLIRenewalPolicy()
        XCTAssertTrue(policy.begin(version:"old",now:date,manual:false))
        XCTAssertFalse(policy.begin(version:"old",now:date,manual:false))
        policy.finish(.needsLogin,now:date)
        XCTAssertFalse(policy.begin(version:"old",now:date.addingTimeInterval(3600),manual:false))
        XCTAssertTrue(policy.begin(version:"old",now:date,manual:true))
        policy.finish(.authorizationRequired,now:date)
        XCTAssertTrue(policy.begin(version:"new",now:date,manual:false))
        policy.finish(.retryLater,now:date)
        XCTAssertFalse(policy.begin(version:"new",now:date.addingTimeInterval(299),manual:false))
        XCTAssertTrue(policy.begin(version:"new",now:date.addingTimeInterval(300),manual:false))
    }
    func testPendingBackupAndVerificationFinishWithoutSpendingRefreshAgain() async throws {
        for failedVerification in [false,true] {
            let io=try fixture(),newer=try login(a,token:"renewed",seconds:3600)
            io.failWrite = !failedVerification
            let first=try await recover(io,native:{try self.set(newer,in:io);return .completed},verify:{_ in
                if failedVerification {throw SafetyError("fixture timeout")};return self.a
            })
            XCTAssertEqual(first,failedVerification ? .verificationPending : .backupPending)
            io.failWrite=false
            let second=try await CLICurrentRecovery.run(target:.init(name:"A",identity:a),io:io,now:{self.date},finishPendingBackup:true,
                contextIsCurrent:{true},gate:{true},native:{XCTFail("do not consume refresh token twice");return .completed},verify:{_ in self.a})
            XCTAssertEqual(second,.renewed);XCTAssertEqual(try CLIBackup(data:io.backups["A"]!).login,newer)
        }
    }
    func testAmbientRefreshOverrideIsNotTheDefaultNativeLogin() {
        let config=AuthenticationConfiguration.inspect(environment:["CLAUDE_CODE_OAUTH_REFRESH_TOKEN":"fixture-override"],documents:[])
        XCTAssertFalse(config.allowsSubscriptionMutation)
    }
    func testMalformedExpiryDoesNotRunCLIOrBecomeLoginRevoked() throws {
        let values: [Any] = [true,-1,"2026-11-02"]
        for value in values {
            let invalid=CLIOwnedLogin(oauth:try CLIJSON.encode(["accessToken":"fake","refreshToken":"fake-refresh","expiresAt":value]),metadata:nil)
            XCTAssertThrowsError(try CLICurrentRecovery.isDue(invalid,now:date))
        }
    }
    func testExplicitNativeRejectionWinsOverUnexpiredLocalTimestamp() async throws {
        let io=try fixture(seconds:3600)
        let result=try await CLICurrentRecovery.run(target:.init(name:"A",identity:a),io:io,now:{self.date},requestNativeCheck:true,
            contextIsCurrent:{true},gate:{true},native:{.loginRequired},verify:{_ in XCTFail("native rejection is not a verified login");return self.a})
        XCTAssertEqual(result,.needsLogin);XCTAssertTrue(io.backups.isEmpty);XCTAssertEqual(io.liveWrites,0)
    }
}
