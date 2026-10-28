import XCTest
@testable import SwitcherCore

@MainActor private final class FileCredentialFixture: CLICredentialIO {
    var primary: Data?, document: Data?, marker: String? = "A"
    var backups: [String: Data] = [:]
    var denyPrimary = false, denyBackup = false, denyFileWrite = false
    var failAfterFileWrite = false, failMarkerOnce = false
    let file: URL
    lazy var router = CLIStoredCredentialRouter(readPrimary: { [unowned self] in
        if self.denyPrimary { throw SafetyError("fixture: locked Keychain") }; return self.primary
    }, writePrimary: { [unowned self] in self.primary = $0 }, readFile: { [unowned self] in
        try CLIPrivateFile.read(self.file)
    }, writeFile: { [unowned self] data in
        if self.denyFileWrite { throw SafetyError("fixture: write denied") }
        try CLIPrivateFile.write(data, to: self.file)
        if self.failAfterFileWrite { self.failAfterFileWrite = false; throw SafetyError("fixture: failed receipt") }
    })
    init(file: URL) { self.file = file }
    func readCredentials() throws -> Data? { try router.read() }
    func writeCredentials(_ data: Data?) throws { try router.write(data) }
    func readIdentityDocument() throws -> Data? { document }
    func writeIdentityDocument(_ data: Data?) throws { document = data }
    func readBackup(_ profile: String) throws -> Data? { backups[profile] }
    func writeBackup(_ profile: String, data: Data) throws {
        if denyBackup { throw SafetyError("fixture: backup failed") }; backups[profile] = data
    }
    func readMarker() throws -> String? { marker }
    func writeMarker(_ value: String?) throws {
        if failMarkerOnce { failMarkerOnce = false; throw SafetyError("fixture: marker failed") }; marker = value
    }
}

@MainActor final class CLIFileCredentialTests: FixtureTest {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var a: CLIIdentity { .init(accountID: "a", organizationID: "org-a", email: "a@example.test") }
    private var b: CLIIdentity { .init(accountID: "b", organizationID: "org-b", email: "b@example.test") }
    private var profiles: [CLIProfileIdentity] { [.init(name: "A", identity: a), .init(name: "B", identity: b)] }
    private func login(_ identity: CLIIdentity) throws -> CLIOwnedLogin {
        .init(oauth: try CLIJSON.encode(["accessToken": "fake-" + identity.accountID!, "refreshToken": "fake-refresh", "expiresAt": date.addingTimeInterval(3600).timeIntervalSince1970 * 1000]),
              metadata: try CLIJSON.encode(["accountUuid": identity.accountID!, "organizationUuid": identity.organizationID!, "emailAddress": identity.email!]))
    }
    private func remote(_ token: String) async throws -> CLIIdentity {
        if token == "fake-a" { return a }; if token == "fake-b" { return b }; throw SafetyError("fixture")
    }
    private func fixture(mirrored: Bool = false) throws -> (FileCredentialFixture, CLITransaction) {
        let file = try directory("fake-home/.claude").appendingPathComponent(".credentials.json")
        let io = FileCredentialFixture(file: file), current = try login(a)
        try CLIPrivateFile.write(CLIJSON.replacing(CLIJSON.encode(["mcpOAuth": ["keep": "file"]]), key: "claudeAiOauth", with: current.oauth), to: file)
        if mirrored { io.primary = try CLIJSON.replacing(CLIJSON.encode(["other": "keychain"]), key: "claudeAiOauth", with: current.oauth) }
        io.document = try CLIJSON.replacing(CLIJSON.encode(["projects": ["keep": true]]), key: "oauthAccount", with: current.metadata)
        io.backups["B"] = try CLIBackup.verifiedData(login: login(b), identity: b, now: date)
        return (io, CLITransaction(io: io, now: { self.date }))
    }
    private func prepare(_ tx: CLITransaction) async throws -> PreparedCLISwitch {
        try await tx.prepare(target: profiles[1], profiles: profiles, remote: remote)
    }
    func testFileOnlyRoundTripPreservesRefreshCredentialsOtherFieldsAndBackups() async throws {
        let (io, tx) = try fixture()
        let first = try await prepare(tx); try tx.persistOutgoing(first); _ = try tx.apply(first)
        XCTAssertEqual(try tx.readOwned().identity?.accountID, "b"); XCTAssertNil(io.primary)
        let second = try await tx.prepare(target: profiles[0], profiles: profiles, remote: remote)
        try tx.persistOutgoing(second); _ = try tx.apply(second)
        XCTAssertEqual(try tx.readOwned(), try login(a)); XCTAssertNotNil(io.backups["A"]); XCTAssertNotNil(io.backups["B"])
        XCTAssertEqual(try CLIJSON.object(CLIPrivateFile.read(io.file)!) ["mcpOAuth"] as? [String: String], ["keep": "file"])
        XCTAssertNotNil(try CLIJSON.object(io.document!)["projects"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: io.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testIdenticalDualStoresAreUpdatedTogetherWithoutCopyingUnrelatedFields() async throws {
        let (io, tx) = try fixture(mirrored: true), p = try await prepare(tx)
        try tx.persistOutgoing(p); _ = try tx.apply(p)
        XCTAssertEqual(io.router.kind, .mirrored)
        XCTAssertEqual(try CLIJSON.field(io.primary, key: "claudeAiOauth"), try login(b).oauth)
        let file = try CLIPrivateFile.read(io.file)
        XCTAssertEqual(try CLIJSON.field(file, key: "claudeAiOauth"), try login(b).oauth)
        XCTAssertEqual(try CLIJSON.object(io.primary!)["other"] as? String, "keychain")
        XCTAssertNil(try CLIJSON.object(file!)["other"])
    }
    func testConflictingDualStoresCannotQuitOrBackUp() async throws {
        let (io, tx) = try fixture(); io.primary = try CLIJSON.replacing(nil, key: "claudeAiOauth", with: login(b).oauth)
        var quit = false
        do { _ = try await CLILinkedSwitch.run(transaction: tx, target: profiles[1], profiles: profiles, remote: remote, quit: { quit = true; return true }, move: { XCTFail(); return {} }); XCTFail() }
        catch { XCTAssertTrue(error is CLIPreparationFailure) }
        XCTAssertFalse(quit); XCTAssertNil(io.backups["A"])
    }
    func testLockedKeychainIsNotMisreadAsAbsentPrimary() async throws {
        let (io, tx) = try fixture(); io.denyPrimary = true
        do { _ = try await prepare(tx); XCTFail() } catch {}
        XCTAssertNil(io.backups["A"])
    }
    func testPrimaryContainerWithoutOAuthWinsWhenBothStoresHaveNoLogin() throws {
        let (io, _) = try fixture()
        io.primary = try CLIJSON.encode(["mcpOAuth": ["keep": "primary"]])
        try CLIPrivateFile.write(CLIJSON.encode(["other": "file"]), to: io.file)
        _ = try io.readCredentials(); XCTAssertEqual(io.router.kind, .keychain)
        try io.writeCredentials(CLIJSON.replacing(io.primary, key: "claudeAiOauth", with: login(b).oauth))
        XCTAssertEqual(try CLIJSON.field(io.primary, key: "claudeAiOauth"), try login(b).oauth)
        XCTAssertNil(try CLIJSON.field(CLIPrivateFile.read(io.file), key: "claudeAiOauth"))
    }
    func testNonOAuthPrimaryWithFileLoginIsAmbiguousNotAnEmptyPrimary() throws {
        let (io, _) = try fixture(); io.primary = try CLIJSON.encode(["mcpOAuth": ["keep": "primary"]])
        let before = try CLIPrivateFile.read(io.file)
        XCTAssertThrowsError(try io.readCredentials())
        XCTAssertEqual(try CLIPrivateFile.read(io.file), before)
    }
    func testBackupFailureOccursBeforeFileOrDesktopMutation() async throws {
        let (io, tx) = try fixture(), before = try CLIPrivateFile.read(io.file); io.denyBackup = true
        do { _ = try await CLILinkedSwitch.run(transaction: tx, target: profiles[1], profiles: profiles, remote: remote, quit: { XCTFail(); return true }, move: { XCTFail(); return {} }); XCTFail() } catch {}
        XCTAssertEqual(try CLIPrivateFile.read(io.file), before); XCTAssertEqual(io.marker, "A")
    }
    func testFileWriteFailureRollsBackMirroredPrimaryBeforeDesktopRestore() async throws {
        let (io, tx) = try fixture(mirrored: true), before = io.primary; io.denyFileWrite = true
        var undone = false
        do { _ = try await CLILinkedSwitch.run(transaction: tx, target: profiles[1], profiles: profiles, remote: remote, quit: { true }, move: { { undone = true } }); XCTFail() } catch {}
        XCTAssertTrue(undone); XCTAssertEqual(io.primary, before); XCTAssertEqual(try tx.readOwned(), try login(a))
    }
    func testFailureAfterFileCommitRestoresBothCopies() async throws {
        let (io, tx) = try fixture(mirrored: true), p = try await prepare(tx)
        try tx.persistOutgoing(p); io.failAfterFileWrite = true
        XCTAssertThrowsError(try tx.apply(p)); XCTAssertEqual(try tx.readOwned(), try login(a))
        XCTAssertEqual(try CLIJSON.field(io.primary, key: "claudeAiOauth"), try login(a).oauth)
    }
    func testMarkerFailureRestoresFileAndIdentity() async throws {
        let (io, tx) = try fixture(), p = try await prepare(tx); try tx.persistOutgoing(p); io.failMarkerOnce = true
        XCTAssertThrowsError(try tx.apply(p)); XCTAssertEqual(try tx.readOwned(), try login(a)); XCTAssertEqual(io.marker, "A")
    }
    func testRefreshDuringVerificationIsPreservedWithZeroWrites() async throws {
        let (io, tx) = try fixture(), external = try CLIJSON.replacing(nil, key: "claudeAiOauth", with: CLIJSON.encode(["accessToken": "external-fake"]))
        do {
            _ = try await tx.prepare(target: profiles[1], profiles: profiles, remote: { token in
                try CLIPrivateFile.write(external, to: io.file); return try await self.remote(token)
            }); XCTFail()
        } catch {}
        XCTAssertEqual(try CLIPrivateFile.read(io.file), external); XCTAssertNil(io.backups["A"])
    }
    func testManualSyncMissingTargetKeepsCurrentLoginAndNoBackupWrites() async throws {
        let (io, tx) = try fixture(); io.backups.removeAll()
        do { _ = try await tx.prepare(target: profiles[1], profiles: profiles, requiresTargetLogin: true, remote: remote); XCTFail() } catch {}
        XCTAssertEqual(try tx.readOwned(), try login(a)); XCTAssertTrue(io.backups.isEmpty)
    }
    func testFirstTimeLinkedTargetCanStillRequestLoginWithoutRemovingOtherCredentials() async throws {
        let (io, tx) = try fixture(); io.backups.removeAll(); let p = try await prepare(tx)
        try tx.persistOutgoing(p); XCTAssertEqual(try tx.apply(p), .needsLogin)
        XCTAssertFalse(try tx.readOwned().hasSecrets); XCTAssertNotNil(io.backups["A"])
        XCTAssertNotNil(try CLIJSON.object(CLIPrivateFile.read(io.file)!) ["mcpOAuth"])
    }
    func testMalformedFileAndInsecurePermissionsAreNotEmptyLogins() throws {
        let (io, _) = try fixture(); try CLIPrivateFile.write(Data("invalid".utf8), to: io.file)
        XCTAssertThrowsError(try io.readCredentials())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: io.file.path)
        XCTAssertThrowsError(try CLIPrivateFile.read(io.file))
    }
    func testSymlinkedFileAndParentAreRejectedWithoutChangingDestination() throws {
        let dir = try directory("private"), destination = dir.appendingPathComponent("target")
        try CLIPrivateFile.write(Data("{}".utf8), to: destination)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try CLIPrivateFile.read(link)); XCTAssertThrowsError(try CLIPrivateFile.write(Data("new".utf8), to: link))
        let parentLink = folder.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: dir)
        XCTAssertThrowsError(try CLIPrivateFile.read(parentLink.appendingPathComponent("target")))
        XCTAssertEqual(try CLIPrivateFile.read(destination), Data("{}".utf8))
    }
}
