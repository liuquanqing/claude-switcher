import Foundation
import XCTest
@testable import SwitcherCore

@MainActor private final class BackupFixture: CLICredentialIO {
    let identity = CLIIdentity(accountID: "fixture-account", organizationID: "fixture-org", email: "fixture@example.invalid")
    var credentials: Data?
    var document: Data?
    var backup: Data?
    var liveWrites = 0
    var backupWrites = 0
    var rejectWrite = false
    var discardWrite = false

    init() throws {
        credentials = try CLIJSON.encode(["claudeAiOauth": [
            "accessToken": "fictional-new-access", "refreshToken": "fictional-new-refresh",
            "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        ]])
        document = try CLIJSON.encode(["oauthAccount": ["accountUuid": identity.accountID!,
            "organizationUuid": identity.organizationID!, "emailAddress": identity.email!]])
        let old = CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken": "fictional-old",
            "refreshToken": "fictional-old-refresh", "expiresAt": 1]), metadata: try CLIJSON.field(document, key: "oauthAccount"))
        backup = try CLIBackup.verifiedData(login: old, identity: identity, now: .distantPast)
    }
    func readCredentials() throws -> Data? { credentials }
    func readIdentityDocument() throws -> Data? { document }
    func readBackup(_ profile: String) throws -> Data? { backup }
    func writeBackup(_ profile: String, data: Data) throws {
        if rejectWrite { throw SafetyError("fixture backup permission denied") }
        backupWrites += 1
        if !discardWrite { backup = data }
    }
    func readMarker() throws -> String? { "Fixture" }
    func writeMarker(_ value: String?) throws { liveWrites += 1; throw SafetyError("no live writes") }
    func writeCredentials(_ data: Data?) throws { liveWrites += 1; throw SafetyError("no live writes") }
    func writeIdentityDocument(_ data: Data?) throws { liveWrites += 1; throw SafetyError("no live writes") }
    var login: CLIOwnedLogin { get throws { try .init(credentials: credentials, identityDocument: document) } }
}

final class CLICurrentBackupTests: XCTestCase {
    @MainActor func testLocalSnapshotNeedsNoNetworkAndDoesNotInventOnlineVerification() async throws {
        let io = try BackupFixture(), original = try io.login
        // No verified backup yet: a local snapshot is saved without inventing a proof.
        io.backup = nil
        let result = try await CLICurrentBackup.save(target: .init(name: "Fixture", identity: io.identity), io: io,
            contextIsCurrent: { true })
        let backup = try CLIBackup(data: io.backup!)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(backup.login, original)
        XCTAssertNil(backup.verification)
        XCTAssertEqual(try io.login, original)
        XCTAssertEqual(io.liveWrites, 0)
        // A verified backup is never replaced offline, even by a newer-looking local login whose
        // identity block may lag an external sign-in; the next gated verification decides.
        let old = try CLIBackup.verifiedData(login: loginWithexpiry(1), identity: io.identity, now: .distantPast)
        io.backup = old
        let kept = try await CLICurrentBackup.save(target: .init(name: "Fixture", identity: io.identity), io: io, contextIsCurrent: { true })
        XCTAssertEqual(kept, .upToDate)
        XCTAssertEqual(io.backup, old)
    }
    private func loginWithexpiry(_ ms: Double) throws -> CLIOwnedLogin {
        let identity = CLIIdentity(accountID: "fixture-account", organizationID: "fixture-org", email: "fixture@example.invalid")
        return CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken": "fictional-old", "refreshToken": "fictional-old-refresh", "expiresAt": ms]),
                             metadata: try CLIJSON.encode(["accountUuid": identity.accountID!, "organizationUuid": identity.organizationID!, "emailAddress": identity.email!]))
    }
    @MainActor func testFreshLoginReplacesOnlyBackupAndReadbackIsIdempotent() async throws {
        let io = try BackupFixture(), original = try io.login
        var verifications = 0
        for expected in [CLICurrentBackup.Outcome.saved, .upToDate] {
            let result = try await CLICurrentBackup.save(target: .init(name: "Fixture", identity: io.identity), io: io,
                contextIsCurrent: { true }, gate: { true }, verify: { _ in verifications += 1; return io.identity })
            XCTAssertEqual(result, expected)
        }
        XCTAssertEqual(verifications, 1)
        XCTAssertEqual(io.backupWrites, 1)
        XCTAssertEqual(io.liveWrites, 0)
        XCTAssertEqual(try io.login, original)
        XCTAssertEqual(try CLIBackup(data: io.backup!).login, original)
        XCTAssertEqual(try CLIBackup(data: io.backup!).trustedIdentity(), io.identity)
    }

    @MainActor func testVerificationFailurePreservesCurrentLoginAndOldBackup() async throws {
        let io = try BackupFixture(), original = try io.login, old = io.backup
        do {
            _ = try await CLICurrentBackup.save(target: .init(name: "Fixture", identity: io.identity), io: io,
                contextIsCurrent: { true }, gate: { true }, verify: { _ in throw SafetyError("fixture network unavailable") })
            XCTFail("verification failure must not write a backup")
        } catch {}
        XCTAssertEqual(io.backup, old)
        XCTAssertEqual(try io.login, original)
        XCTAssertEqual(io.liveWrites, 0)
    }

    @MainActor func testRotatedLoginDuringVerificationIsNeverOverwrittenOrBackedUpAsCurrent() async throws {
        let io = try BackupFixture(), old = io.backup
        do {
            _ = try await CLICurrentBackup.save(target: .init(name: "Fixture", identity: io.identity), io: io,
                contextIsCurrent: { true }, gate: { true }, verify: { _ in
                    io.credentials = try CLIJSON.encode(["claudeAiOauth": ["accessToken": "fictional-rotated"]])
                    return io.identity
                })
            XCTFail("a changed login must abort")
        } catch {}
        XCTAssertEqual(io.backup, old)
        XCTAssertEqual(io.backupWrites, 0)
        XCTAssertEqual(io.liveWrites, 0)
    }

    @MainActor func testExpiredLoginAndWriteFailuresDoNotModifyLiveLogin() async throws {
        for mode in ["expired", "denied", "readback"] {
            let io = try BackupFixture()
            if mode == "expired" {
                io.credentials = try CLIJSON.encode(["claudeAiOauth": ["accessToken": "fictional-expired",
                    "refreshToken": "fictional-refresh", "expiresAt": 1]])
            }
            io.rejectWrite = mode == "denied"
            io.discardWrite = mode == "readback"
            let original = try io.login, old = io.backup
            do {
                _ = try await CLICurrentBackup.save(target: .init(name: "Fixture", identity: io.identity), io: io,
                    contextIsCurrent: { true }, gate: { true }, verify: { _ in io.identity })
                XCTFail("expired or unwritable backup must report failure")
            } catch {}
            XCTAssertEqual(try io.login, original)
            XCTAssertEqual(io.backup, old)
            XCTAssertEqual(io.liveWrites, 0)
        }
    }
}
