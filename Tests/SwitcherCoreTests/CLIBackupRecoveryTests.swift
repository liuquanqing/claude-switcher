import XCTest
@testable import SwitcherCore

@MainActor final class RecoveryMemoryIO: CLICredentialIO {
    var credentials: Data?, document: Data?, marker: String? = "A"
    var backups: [String: Data] = [:]
    var failWrite = false, corruptReadback = false
    var liveWrites = 0
    func readCredentials() throws -> Data? { credentials }
    func writeCredentials(_ data: Data?) throws { liveWrites += 1; credentials = data }
    func readIdentityDocument() throws -> Data? { document }
    func writeIdentityDocument(_ data: Data?) throws { liveWrites += 1; document = data }
    func readMarker() throws -> String? { marker }
    func writeMarker(_ value: String?) throws { liveWrites += 1; marker = value }
    func readBackup(_ name: String) throws -> Data? { backups[name] }
    func writeBackup(_ name: String, data: Data) throws {
        if failWrite { throw SafetyError("fixture denied") }
        backups[name] = corruptReadback ? Data("{}".utf8) : data
    }
}

@MainActor final class CLIBackupRecoveryTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let a = CLIIdentity(accountID: "fixture-a", organizationID: "org-a", email: "same@example.test")
    let b = CLIIdentity(accountID: "fixture-b", organizationID: "org-b", email: "same@example.test")
    func login(_ id: CLIIdentity, token: String, expired: Bool = false, refresh: Bool = true) throws -> CLIOwnedLogin {
        CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken":token,"refreshToken":refresh ? "fake-refresh-"+token : "", "expiresAt":date.addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970*1000]),
                      metadata: try CLIJSON.encode(["accountUuid":id.accountID!,"organizationUuid":id.organizationID!,"emailAddress":id.email!]))
    }
    func raw(_ login: CLIOwnedLogin) throws -> Data {
        try CLIJSON.encode(["claudeAiOauth":CLIJSON.object(login.oauth!),"oauthAccount":CLIJSON.object(login.metadata!)])
    }
    func fixture() throws -> RecoveryMemoryIO {
        let io = RecoveryMemoryIO(), live = try login(a, token: "a")
        io.credentials = try CLIJSON.replacing(nil, key:"claudeAiOauth", with:live.oauth)
        io.document = try CLIJSON.replacing(nil, key:"oauthAccount", with:live.metadata)
        io.backups["B"] = try raw(login(b, token:"old-b", expired:true))
        return io
    }
    func recover(_ io: RecoveryMemoryIO,
                 renew: (CLIOwnedLogin, CLIIdentity) async throws -> CLIRecoveredLogin,
                 remote: ((String) async throws -> CLIIdentity)? = nil) async throws -> CLIBackupRecovery.Outcome {
        try await CLIBackupRecovery.prepare(target:.init(name:"B",identity:b), io:io, now:{self.date}, renew:renew,
            remote:remote ?? { token in guard token == "new-b" else { throw SafetyError("fake stale") }; return self.b })
    }
    func testLegacyRenewalUpgradesBackupWithoutTouchingDefaultAndRoundTrips() async throws {
        let io = try fixture(), oldLive = io.credentials
        var calls = 0, cleaned = false
        let outcome = try await recover(io, renew: { _, _ in
            calls += 1; return CLIRecoveredLogin(login:try self.login(self.b,token:"new-b"),finish:{cleaned = true})
        })
        XCTAssertEqual(outcome,.recovered); XCTAssertTrue(cleaned); XCTAssertEqual(calls,1)
        XCTAssertEqual(io.credentials,oldLive); XCTAssertEqual(io.liveWrites,0)
        XCTAssertEqual(try CLIBackup(data:io.backups["B"]!).trustedIdentity(),b)
        _ = try await recover(io,renew:{_,_ in XCTFail("already valid must not renew"); throw SafetyError("unexpected")})
        let profiles: [CLIProfileIdentity] = [.init(name:"A",identity:a),.init(name:"B",identity:b)]
        let transaction = CLITransaction(io:io,now:{self.date})
        for target in [profiles[1],profiles[0]] {
            _ = try await CLILinkedSwitch.run(transaction:transaction,target:target,profiles:profiles,requiresTargetLogin:true,
                remote:{ $0 == "a" ? self.a : self.b },quit:{true},move:{{}})
            XCTAssertEqual(try transaction.readOwned().identity,target.identity)
        }
        XCTAssertEqual(io.credentials,oldLive)
    }
    func testTrustedExpiredBackupRetainsStoredLoginPathWithoutRenewal() async throws {
        let io = try fixture()
        io.backups["B"] = try CLIBackup.verifiedData(login: login(b, token:"old-b", expired:true), identity:b, now:date.addingTimeInterval(-3600))
        let outcome = try await recover(io, renew:{_,_ in XCTFail("trusted backup should not force rotation"); throw SafetyError("unexpected")})
        XCTAssertEqual(outcome,.notNeeded); XCTAssertEqual(io.liveWrites,0)
        let plan = try await CLITransaction(io:io,now:{self.date}).prepare(target:.init(name:"B",identity:b),
            profiles:[.init(name:"A",identity:a),.init(name:"B",identity:b)],requiresTargetLogin:true,remote:{_ in self.a})
        XCTAssertEqual(plan.restoration,.storedLogin)
    }
    func testLiveTargetWinsOverExpiredParkedBackup() async throws {
        let io = try fixture(), newer = try login(b,token:"new-b")
        io.credentials = try CLIJSON.replacing(nil,key:"claudeAiOauth",with:newer.oauth)
        io.document = try CLIJSON.replacing(nil,key:"oauthAccount",with:newer.metadata)
        let outcome = try await recover(io,renew:{_,_ in XCTFail("must preserve live login"); throw SafetyError("unexpected")})
        XCTAssertEqual(outcome,.notNeeded); XCTAssertEqual(io.liveWrites,0)
    }
    func testMissingRefreshRequiresLoginWithoutMutation() async throws {
        let io = try fixture(); io.backups["B"] = try raw(login(b,token:"old-b",expired:true,refresh:false))
        let before = io.backups
        do { _ = try await recover(io,renew:{_,_ in XCTFail("no refresh secret"); throw SafetyError("unexpected")}); XCTFail() } catch {}
        XCTAssertEqual(io.backups,before); XCTAssertEqual(io.liveWrites,0)
    }
    func testNativeFailureDoesNotConsumeOrOverwriteStoredBackup() async throws {
        let io = try fixture(), before = io.backups
        do { _ = try await recover(io,renew:{_,_ in throw SafetyError("fixture timeout")}); XCTFail() } catch {}
        XCTAssertEqual(io.backups,before); XCTAssertEqual(io.liveWrites,0)
    }
    func testExpiredOutputAndWrongOrganizationAreRejected() async throws {
        for bad in [try login(b,token:"old-b",expired:true), try login(a,token:"new-b")] {
            let io = try fixture(), before = io.backups
            var cleaned = false
            do { _ = try await recover(io,renew:{_,_ in CLIRecoveredLogin(login:bad,finish:{cleaned = true})}); XCTFail() } catch {}
            XCTAssertEqual(io.backups,before); XCTAssertFalse(cleaned)
        }
    }
    func testRemoteMismatchOrFailureRetainsRecoveryAndOldBackup() async throws {
        for mismatch in [false,true] {
            let io = try fixture(), before = io.backups
            var cleaned = false
            do { _ = try await recover(io,renew:{_,_ in CLIRecoveredLogin(login:try self.login(self.b,token:"new-b"),finish:{cleaned = true})},
                remote:{_ in if mismatch { return self.a }; throw SafetyError("fixture 429") }); XCTFail() } catch {}
            XCTAssertEqual(io.backups,before); XCTAssertFalse(cleaned)
        }
    }
    func testConcurrentDefaultOrTargetChangeIsPreserved() async throws {
        for targetChanges in [false,true] {
            let io = try fixture()
            var cleaned = false
            do { _ = try await recover(io,renew:{_,_ in
                if targetChanges { io.backups["B"] = try self.raw(self.login(self.b,token:"external")) }
                else { io.credentials = Data("{}".utf8) }
                return CLIRecoveredLogin(login:try self.login(self.b,token:"new-b"),finish:{cleaned = true})
            }); XCTFail() } catch {}
            XCTAssertFalse(cleaned); XCTAssertEqual(io.liveWrites,0)
            if targetChanges { XCTAssertEqual(try CLIBackup(data:io.backups["B"]!).login.usableAccessToken(now:date),"external") }
            else { XCTAssertEqual(io.credentials,Data("{}".utf8)) }
        }
    }
    func testFailedWriteOrReadbackNeverCleansRenewedCredential() async throws {
        for corrupt in [false,true] {
            let io = try fixture(); io.failWrite = !corrupt; io.corruptReadback = corrupt
            var cleaned = false
            do { _ = try await recover(io,renew:{_,_ in CLIRecoveredLogin(login:try self.login(self.b,token:"new-b"),finish:{cleaned = true})}); XCTFail() }
            catch { XCTAssertTrue(error is CLIRecoveryPersistenceFailure) }
            XCTAssertFalse(cleaned); XCTAssertEqual(io.liveWrites,0)
        }
    }
    func testCleanupFailureDoesNotInvalidateVerifiedBackup() async throws {
        let io = try fixture()
        let outcome = try await recover(io,renew:{_,_ in CLIRecoveredLogin(login:try self.login(self.b,token:"new-b"),finish:{throw SafetyError("fixture cleanup")})})
        XCTAssertEqual(outcome,.recoveredCleanupPending)
        XCTAssertEqual(try CLIBackup(data:io.backups["B"]!).trustedIdentity(),b)
    }
    func testRequiredTargetLoginDoesNotClearDefaultOrQuitDesktop() async throws {
        let io = try fixture(); io.backups.removeAll()
        var quit = false
        do {
            _ = try await CLILinkedSwitch.run(transaction:CLITransaction(io:io,now:{self.date}),target:.init(name:"B",identity:b),
                profiles:[.init(name:"A",identity:a),.init(name:"B",identity:b)],requiresTargetLogin:true,
                remote:{_ in self.a},quit:{quit = true; return true},move:{{}})
            XCTFail()
        } catch {}
        XCTAssertFalse(quit); XCTAssertEqual(io.liveWrites,0); XCTAssertTrue(io.backups.isEmpty)
    }
}
