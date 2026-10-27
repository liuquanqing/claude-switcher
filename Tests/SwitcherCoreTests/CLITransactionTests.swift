import XCTest
@testable import SwitcherCore

@MainActor private final class MemoryCLI: CLICredentialIO {
    var credentials: Data?, document: Data?, marker: String?
    var backups: [String: Data] = [:]
    var events: [String] = []
    var denyRead = false, denyBackup = false
    var denyMarkerRead = false
    var markerWriter: ((String?) throws -> Void)?
    var credentialWriter: ((Data?) throws -> Void)?
    var identityWriter: ((Data?) throws -> Void)?
    var backupWriter: ((String, Data) throws -> Void)?
    func readCredentials() throws -> Data? { if denyRead { throw SafetyError("denied") }; return credentials }
    func writeCredentials(_ data: Data?) throws {
        events.append("credentials")
        if let credentialWriter { try credentialWriter(data) } else { credentials = data }
    }
    func readIdentityDocument() throws -> Data? { document }
    func writeIdentityDocument(_ data: Data?) throws {
        events.append("identity")
        if let identityWriter { try identityWriter(data) } else { document = data }
    }
    func readBackup(_ profile: String) throws -> Data? { backups[profile] }
    func writeBackup(_ profile: String, data: Data) throws {
        events.append("backup:" + profile)
        if denyBackup { throw SafetyError("backup denied") }
        if let backupWriter { try backupWriter(profile, data); return }
        backups[profile] = data
    }
    func readMarker() throws -> String? { if denyMarkerRead { throw SafetyError("marker denied") }; return marker }
    func writeMarker(_ value: String?) throws {
        events.append("marker")
        if let markerWriter { try markerWriter(value) } else { marker = value }
    }
}

@MainActor final class CLITransactionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var a: CLIIdentity { CLIIdentity(accountID: "account-a", organizationID: "org-a", email: "same@example.test") }
    private var b: CLIIdentity { CLIIdentity(accountID: "account-b", organizationID: "org-b", email: "same@example.test") }
    private var profiles: [CLIProfileIdentity] { [.init(name: "A", identity: a), .init(name: "B", identity: b)] }
    private func login(_ identity: CLIIdentity, token: String, expired: Bool = false, refresh: Bool = true) throws -> CLIOwnedLogin {
        let oauth: [String: Any] = ["accessToken": token, "refreshToken": refresh ? "refresh-" + token : "",
                                    "expiresAt": date.addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970 * 1000]
        return CLIOwnedLogin(oauth: try CLIJSON.encode(oauth), metadata: try CLIJSON.encode([
            "accountUuid": identity.accountID!, "organizationUuid": identity.organizationID!, "emailAddress": identity.email!]))
    }
    private func payload(_ value: CLIOwnedLogin) throws -> Data {
        try CLIJSON.encode(["claudeAiOauth": CLIJSON.object(value.oauth!), "oauthAccount": CLIJSON.object(value.metadata!)])
    }
    private func fixture() throws -> (MemoryCLI, CLITransaction) {
        let io = MemoryCLI(), current = try login(a, token: "access-a")
        io.credentials = try CLIJSON.replacing(CLIJSON.encode(["mcpOAuth": ["shared": "keep"]]), key: "claudeAiOauth", with: current.oauth)
        io.document = try CLIJSON.replacing(CLIJSON.encode(["projects": ["fixture": true]]), key: "oauthAccount", with: current.metadata)
        io.marker = "A"; io.backups["B"] = try payload(login(b, token: "access-b"))
        return (io, CLITransaction(io: io, now: { self.date }))
    }
    private func remote(_ token: String) async throws -> CLIIdentity {
        if token == "access-a" { return a }; if token == "access-b" { return b }
        throw SafetyError("unknown token")
    }
    private func plan(_ transaction: CLITransaction) async throws -> PreparedCLISwitch {
        try await transaction.prepare(target: profiles[1], profiles: profiles, remote: remote)
    }

    func testRoundTripPreservesBothAccountsAndUnrelatedFields() async throws {
        let (io, transaction) = try fixture()
        var p = try await plan(transaction)
        XCTAssertTrue(io.events.isEmpty)
        try transaction.persistOutgoing(p); XCTAssertEqual(try transaction.apply(p), .verifiedLogin)
        XCTAssertEqual(try transaction.readOwned().identity?.accountID, b.accountID)
        p = try await transaction.prepare(target: profiles[0], profiles: profiles, remote: remote)
        try transaction.persistOutgoing(p); _ = try transaction.apply(p)
        XCTAssertEqual(try transaction.readOwned().identity?.accountID, a.accountID)
        XCTAssertEqual(try CLIJSON.object(io.credentials!)["mcpOAuth"] as? [String: String], ["shared": "keep"])
        XCTAssertNotNil(try CLIJSON.object(io.document!)["projects"])
        XCTAssertNotNil(io.backups["A"]); XCTAssertNotNil(io.backups["B"])
    }
    func testDeniedReadCannotQuitOrMoveDesktop() async throws {
        let (io, transaction) = try fixture(); io.denyRead = true
        do {
            _ = try await CLILinkedSwitch.run(transaction: transaction, target: profiles[1], profiles: profiles, remote: remote,
                quit: { io.events.append("quit"); return true }, move: { io.events.append("move"); return {} })
            XCTFail("read should fail")
        } catch { XCTAssertTrue(error is CLIPreparationFailure); XCTAssertTrue(io.events.isEmpty) }
    }
    func testBackupFailureCannotQuitOrMoveDesktop() async throws {
        let (io, transaction) = try fixture(); io.denyBackup = true
        do {
            _ = try await CLILinkedSwitch.run(transaction: transaction, target: profiles[1], profiles: profiles, remote: remote,
                quit: { io.events.append("quit"); return true }, move: { io.events.append("move"); return {} })
            XCTFail("backup should fail")
        } catch { XCTAssertFalse(io.events.contains("quit")); XCTAssertFalse(io.events.contains("move")); XCTAssertEqual(io.marker, "A") }
    }
    func testPartiallyWrittenBackupsDoNotOfferDesktopOnlyContinuation() async throws {
        let (io, transaction) = try fixture(); let before = io.credentials
        let targetBefore = io.backups["B"]
        io.backupWriter = { profile, data in
            if profile == "B" { throw SafetyError("fixture second write denied") }
            io.backups[profile] = data
        }
        defer { io.backupWriter = nil }
        do {
            _ = try await CLILinkedSwitch.run(transaction: transaction, target: profiles[1], profiles: profiles, remote: remote,
                quit: { io.events.append("quit"); return true }, move: { io.events.append("move"); return {} })
            XCTFail("target backup write must fail")
        } catch {
            XCTAssertFalse(error is CLIPreparationFailure)
            XCTAssertNotNil(io.backups["A"])
            XCTAssertEqual(io.backups["B"], targetBefore)
            XCTAssertEqual(io.credentials, before)
            XCTAssertFalse(io.events.contains("quit")); XCTAssertFalse(io.events.contains("move"))
        }
    }
    func testTargetBackupReadbackFailureDoesNotOfferContinuation() async throws {
        let (io, transaction) = try fixture(); let original = io.credentials
        io.backupWriter = { profile, data in io.backups[profile] = profile == "B" ? Data("{}".utf8) : data }
        defer { io.backupWriter = nil }
        do {
            _ = try await CLILinkedSwitch.run(transaction: transaction, target: profiles[1], profiles: profiles, remote: remote,
                quit: { io.events.append("quit"); return true }, move: { io.events.append("move"); return {} })
            XCTFail("target backup readback must fail")
        } catch {
            XCTAssertFalse(error is CLIPreparationFailure)
            XCTAssertEqual(io.credentials, original)
            XCTAssertFalse(io.events.contains("quit")); XCTAssertFalse(io.events.contains("move"))
        }
    }
    func testEmptyTargetCannotEraseWorkingLogin() async throws {
        let (io, transaction) = try fixture(); let before = io.credentials
        io.backups["B"] = try CLIJSON.encode(["claudeAiOauth": ["accessToken": "", "refreshToken": ""], "oauthAccount": CLIJSON.object(login(b, token: "access-b").metadata!)])
        do { _ = try await plan(transaction); XCTFail("empty target") }
        catch { XCTAssertEqual(io.credentials, before); XCTAssertTrue(io.events.isEmpty) }
    }
    func testSameEmailDifferentOrganizationDoesNotMatch() async throws {
        let (io, transaction) = try fixture()
        io.backups["B"] = try payload(login(CLIIdentity(accountID: b.accountID, organizationID: "wrong-org", email: b.email), token: "access-b"))
        do { _ = try await plan(transaction); XCTFail("organization mismatch") }
        catch { XCTAssertTrue(io.events.isEmpty) }
    }
    func testWrongIdentityBlockNeverFiledUnderItsClaimedAccount() async throws {
        let (io, transaction) = try fixture()
        io.document = try CLIJSON.replacing(io.document, key: "oauthAccount", with: login(b, token: "access-b").metadata)
        do { _ = try await plan(transaction); XCTFail("token/metadata mismatch") }
        catch { XCTAssertNil(io.backups["A"]); XCTAssertTrue(io.events.isEmpty) }
    }
    func testStaleMarkerIsNotIdentityAuthority() async throws {
        let (io, transaction) = try fixture(); io.marker = "B"
        let p = try await plan(transaction); try transaction.persistOutgoing(p); _ = try transaction.apply(p)
        XCTAssertNotNil(io.backups["A"])
        XCTAssertEqual(try CLIBackup(data: io.backups["A"]!).login.identity?.accountID, a.accountID)
    }
    func testExpiredUnprovenBackupIsRejectedBeforeMutation() async throws {
        let (io, transaction) = try fixture(); io.backups["B"] = try payload(login(b, token: "access-b", expired: true))
        do { _ = try await plan(transaction); XCTFail("unverified expired login") }
        catch { XCTAssertTrue(io.events.isEmpty) }
    }
    func testExpiredLegacyTargetCannotQuitDesktopOrOverwriteItsBackup() async throws {
        let (io, transaction) = try fixture()
        let legacy = try payload(login(b, token: "access-b", expired: true))
        io.backups["B"] = legacy
        do {
            _ = try await CLILinkedSwitch.run(transaction: transaction, target: profiles[1], profiles: profiles, remote: remote,
                quit: { io.events.append("quit"); return true }, move: { io.events.append("move"); return {} })
            XCTFail("legacy backup needs login before linked switching")
        } catch {
            XCTAssertTrue(io.events.isEmpty)
            XCTAssertEqual(io.backups["B"], legacy)
            XCTAssertEqual(try transaction.readOwned().identity?.accountID, a.accountID)
        }
    }
    func testCLIWriteFailureRestoresActualTemporaryDesktopDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("Claude"), parked = root.appendingPathComponent("Profiles")
        let target = parked.appendingPathComponent("B"), marker = parked.appendingPathComponent(".current")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("A-data".utf8).write(to: live.appendingPathComponent("data"))
        try Data("B-data".utf8).write(to: target.appendingPathComponent("data"))
        try Data("A".utf8).write(to: marker)
        let (io, transaction) = try fixture()
        io.identityWriter = { _ in throw SafetyError("fixture denied") }
        do {
            _ = try await CLILinkedSwitch.run(transaction: transaction, target: profiles[1], profiles: profiles, remote: remote,
                quit: { true }, move: { try ProfileTransaction(live: live, parked: parked, marker: marker).activate(from: "A", to: "B") })
            XCTFail("write failure")
        } catch {
            XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("data")), "A-data")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("data")), "B-data")
            XCTAssertEqual(try String(contentsOf: marker), "A")
            XCTAssertEqual(try transaction.readOwned().identity?.accountID, a.accountID)
        }
    }
    func testVerifiedExpiredBackupWithRefreshIsRestoredAsPending() async throws {
        let (io, transaction) = try fixture(); let oldDate = date.addingTimeInterval(-3600)
        io.backups["B"] = try CLIBackup.verifiedData(login: login(b, token: "access-b", expired: true), identity: b, now: oldDate)
        let p = try await plan(transaction); XCTAssertEqual(p.restoration, .storedLogin)
        try transaction.persistOutgoing(p); XCTAssertEqual(try transaction.apply(p), .storedLogin)
        XCTAssertEqual(try CLIBackup(data: io.backups["B"]!).verification?.checkedAt, oldDate)
    }
    func testExpiredBackupWithoutRefreshIsNotUsableEvenWithProof() async throws {
        let (io, transaction) = try fixture()
        io.backups["B"] = try CLIBackup.verifiedData(login: login(b, token: "access-b", expired: true, refresh: false), identity: b, now: date.addingTimeInterval(-3600))
        do { _ = try await plan(transaction); XCTFail("no refresh") }
        catch { XCTAssertTrue(io.events.isEmpty) }
    }
    func testCredentialChangeDuringRemoteCheckAborts() async throws {
        let (io, transaction) = try fixture()
        do {
            _ = try await transaction.prepare(target: profiles[1], profiles: profiles, remote: { token in
                if token == "access-b" { io.credentials = try CLIJSON.replacing(io.credentials, key: "claudeAiOauth", with: self.login(self.a, token: "external").oauth) }
                return try await self.remote(token)
            }); XCTFail("changed login")
        } catch { XCTAssertTrue(io.events.isEmpty) }
    }
    func testTargetBackupChangeBeforeQuitAborts() async throws {
        let (io, transaction) = try fixture(); let p = try await plan(transaction)
        io.backups["B"] = try payload(login(b, token: "external"))
        XCTAssertThrowsError(try transaction.persistOutgoing(p)); XCTAssertTrue(io.events.isEmpty)
    }
    func testWriteFailureRestoresOwnedFieldsButKeepsConcurrentMCPUpdate() async throws {
        let (io, transaction) = try fixture(); let original = try transaction.readOwned(); let p = try await plan(transaction)
        try transaction.persistOutgoing(p)
        var first = true
        io.identityWriter = { data in
            if first {
                first = false
                var root = try CLIJSON.object(io.credentials!); root["mcpOAuth"] = ["changed": "keep-new"]
                io.credentials = try CLIJSON.encode(root); throw SafetyError("write denied")
            }
            io.document = data
        }
        XCTAssertThrowsError(try transaction.apply(p))
        XCTAssertEqual(try transaction.readOwned(), original)
        XCTAssertEqual(try CLIJSON.object(io.credentials!)["mcpOAuth"] as? [String: String], ["changed": "keep-new"])
        XCTAssertEqual(io.marker, "A")
    }
    func testReadbackFailureTriggersDesktopUndo() async throws {
        let (io, transaction) = try fixture(); var first = true
        io.identityWriter = { data in if first { first = false; return }; io.document = data }
        do {
            _ = try await CLILinkedSwitch.run(transaction: transaction, target: profiles[1], profiles: profiles, remote: remote,
                quit: { io.events.append("quit"); return true }, move: { io.events.append("move"); return { io.events.append("undo") } })
            XCTFail("silent write must fail verification")
        } catch {
            XCTAssertFalse(error is CLIPreparationFailure)
            XCTAssertTrue(io.events.contains("undo")); XCTAssertEqual(io.marker, "A")
        }
    }
    func testRollbackDoesNotOverwriteExternallyReplacedLogin() async throws {
        let (io, transaction) = try fixture(); let p = try await plan(transaction); try transaction.persistOutgoing(p)
        io.identityWriter = { _ in
            io.credentials = try CLIJSON.replacing(io.credentials, key: "claudeAiOauth", with: self.login(self.a, token: "external").oauth)
            throw SafetyError("failed")
        }
        do { _ = try transaction.apply(p); XCTFail("rollback cannot be confirmed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未确认")) }
        let token = try CLIJSON.object(CLIJSON.field(io.credentials, key: "claudeAiOauth")!)["accessToken"] as? String
        XCTAssertEqual(token, "external")
    }
    func testMissingTargetClearsOnlyOwnedLoginAndReportsNeedsLogin() async throws {
        let (io, transaction) = try fixture(); io.backups["B"] = nil
        let p = try await plan(transaction); try transaction.persistOutgoing(p)
        XCTAssertEqual(try transaction.apply(p), .needsLogin)
        XCTAssertNil(try transaction.readOwned().oauth); XCTAssertNotNil(try CLIJSON.object(io.credentials!)["mcpOAuth"])
        XCTAssertNotNil(io.backups["A"])
    }
    func testSyncToCurrentAccountDoesNotClearItsFirstLogin() async throws {
        let (io, transaction) = try fixture(); let original = try transaction.readOwned()
        let p = try await transaction.prepare(target: profiles[0], profiles: profiles, remote: remote)
        try transaction.persistOutgoing(p); _ = try transaction.apply(p)
        XCTAssertEqual(try transaction.readOwned(), original); XCTAssertNotNil(io.backups["A"])
    }
    func testErrorDoesNotRevealRemoteCredentialText() async throws {
        let (io, transaction) = try fixture()
        do {
            _ = try await transaction.prepare(target: profiles[1], profiles: profiles, remote: { _ in throw SafetyError("access-a refresh-secret") })
            XCTFail("remote error")
        } catch { XCTAssertFalse(error.localizedDescription.contains("access-a")); XCTAssertTrue(io.events.isEmpty) }
    }
    func testMarkerReadFailureIsDiscoveredBeforeQuit() async throws {
        let (io, transaction) = try fixture(); io.denyMarkerRead = true
        do { _ = try await plan(transaction); XCTFail("marker denied") }
        catch { XCTAssertTrue(io.events.isEmpty) }
    }
    func testExistingEmptyRecordsAreRetainedOnRollback() async throws {
        let (io, transaction) = try fixture(); io.credentials = Data("{}".utf8); io.document = Data("{}".utf8); io.marker = nil
        let p = try await plan(transaction); try transaction.persistOutgoing(p)
        io.identityWriter = { _ in throw SafetyError("denied") }
        XCTAssertThrowsError(try transaction.apply(p))
        XCTAssertEqual(io.credentials, Data("{}".utf8)); XCTAssertEqual(io.document, Data("{}".utf8))
        XCTAssertNil(io.marker)
    }
    func testExternalMarkerIsNotClobberedByRollback() async throws {
        let (io, transaction) = try fixture(); let p = try await plan(transaction); try transaction.persistOutgoing(p)
        io.markerWriter = { _ in io.marker = "external" }
        do { _ = try transaction.apply(p); XCTFail("marker changed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未确认")) }
        XCTAssertEqual(io.marker, "external")
    }
    func testSourceSlotCannotOverwriteAnotherPrincipalBackup() async throws {
        let (io, transaction) = try fixture()
        let preserved = try payload(login(b, token: "access-b")); io.backups["A"] = preserved
        do { _ = try await plan(transaction); XCTFail("slot collision") }
        catch { XCTAssertEqual(io.backups["A"], preserved); XCTAssertTrue(io.events.isEmpty) }
    }
    func testExternallyRemovedMarkerIsPreserved() async throws {
        let (io, transaction) = try fixture(); let p = try await plan(transaction); try transaction.persistOutgoing(p)
        io.markerWriter = { _ in io.marker = nil }
        do { _ = try transaction.apply(p); XCTFail("marker removal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未确认")) }
        XCTAssertNil(io.marker)
    }
}
