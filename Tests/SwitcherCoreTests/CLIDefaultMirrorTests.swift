import XCTest
@testable import SwitcherCore

@MainActor private final class MirrorIO: CLICredentialIO {
    var credentials: Data?, document: Data?, marker: String?
    var backups: [String: Data] = [:]
    var events: [String] = []
    var denyBackupWrite = false
    var credentialWriter: ((Data?) throws -> Void)?
    func readCredentials() throws -> Data? { credentials }
    func writeCredentials(_ data: Data?) throws {
        events.append("credentials")
        if let credentialWriter { try credentialWriter(data) } else { credentials = data }
    }
    func readIdentityDocument() throws -> Data? { document }
    func writeIdentityDocument(_ data: Data?) throws { events.append("identity"); document = data }
    func readBackup(_ profile: String) throws -> Data? { backups[profile] }
    func writeBackup(_ profile: String, data: Data) throws {
        events.append("backup:" + profile)
        if denyBackupWrite { throw SafetyError("fixture backup denied") }
        backups[profile] = data
    }
    func readMarker() throws -> String? { marker }
    func writeMarker(_ value: String?) throws { events.append("marker"); marker = value }
}

@MainActor final class CLIDefaultMirrorTests: FixtureTest {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var a: CLIIdentity { CLIIdentity(accountID: "account-a", organizationID: "org-a", email: "a@example.test") }
    private var b: CLIIdentity { CLIIdentity(accountID: "account-b", organizationID: "org-b", email: "b@example.test") }
    private var profiles: [CLIProfileIdentity] { [.init(name: "Personal", identity: a), .init(name: "Design", identity: b)] }
    private func login(_ identity: CLIIdentity, token: String, expired: Bool = false) throws -> CLIOwnedLogin {
        CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken": token, "refreshToken": "refresh-" + token,
                                                 "expiresAt": date.addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970 * 1000]),
                      metadata: try CLIJSON.encode(["accountUuid": identity.accountID!, "organizationUuid": identity.organizationID!, "emailAddress": identity.email!]))
    }
    private func remote(_ token: String) async throws -> CLIIdentity {
        if token == "access-a" || token == "access-a2" { return a }
        if token == "access-b" { return b }
        throw SafetyError("fixture unknown token")
    }
    private func writeIsolated(_ directory: URL, _ value: CLIOwnedLogin, extra: [String: Any] = [:]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try CLIPrivateFile.write(CLIJSON.replacing(nil, key: "claudeAiOauth", with: value.oauth), to: directory.appendingPathComponent(".credentials.json"))
        var document = extra
        document["oauthAccount"] = try CLIJSON.object(value.metadata!)
        try CLIPrivateFile.write(CLIJSON.encode(document), to: directory.appendingPathComponent(".claude.json"))
    }
    /// Default currently holds A; B has its own isolated directory with transcripts.
    private func fixture() throws -> (home: URL, io: MirrorIO, repository: CLIBindingRepository, isolatedB: URL) {
        let home = try directory("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let io = MirrorIO(), current = try login(a, token: "access-a")
        io.credentials = try CLIJSON.replacing(CLIJSON.encode(["mcpOAuth": ["shared": "keep"]]), key: "claudeAiOauth", with: current.oauth)
        io.document = try CLIJSON.replacing(CLIJSON.encode(["projects": ["keep": true], "theme": "dark"]), key: "oauthAccount", with: current.metadata)
        io.marker = "Personal"
        let isolatedB = try CLIBinding.directory(for: .isolated, identity: b, home: home)
        try writeIsolated(isolatedB, login(b, token: "access-b"), extra: ["isolatedOnly": true])
        try Data("prompt one\n".utf8).write(to: isolatedB.appendingPathComponent("history.jsonl"))
        let project = isolatedB.appendingPathComponent("projects/-Users-fixture-work")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{\"type\":\"user\"}\n".utf8).write(to: project.appendingPathComponent("session-1.jsonl"))
        try Data("{\"type\":\"user\"}\n".utf8).write(to: project.appendingPathComponent("session-2.jsonl"))
        let repository = CLIBindingRepository(file: home.appendingPathComponent("state/cli-bindings.json"), home: home)
        return (home, io, repository, isolatedB)
    }
    private func follow(_ fixture: (home: URL, io: MirrorIO, repository: CLIBindingRepository, isolatedB: URL),
                        before: [Int32] = [], now: [Int32] = []) async throws -> CLIDefaultMirror.Outcome {
        try await CLIDefaultMirror.follow(transaction: CLITransaction(io: fixture.io, now: { self.date }), target: profiles[1], profiles: profiles,
                                          home: fixture.home, repository: fixture.repository, remote: remote, now: { self.date },
                                          terminalsBefore: { before }, terminalsNow: { now })
    }

    func testFollowCopiesIsolatedLoginKeepsUnrelatedFieldsAndSharesTranscripts() async throws {
        let f = try fixture()
        let outcome = try await follow(f)
        XCTAssertEqual(outcome.restoration, .verifiedLogin)
        XCTAssertEqual(outcome.linkedTranscripts, 3)
        let live = try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document)
        XCTAssertEqual(try live.identity?.accountID, b.accountID)
        XCTAssertEqual(try CLIJSON.object(f.io.credentials!)["mcpOAuth"] as? [String: String], ["shared": "keep"])
        XCTAssertEqual(try CLIJSON.object(f.io.document!)["theme"] as? String, "dark")
        XCTAssertNotNil(try CLIJSON.object(f.io.document!)["projects"])
        XCTAssertNil(try CLIJSON.object(f.io.document!)["isolatedOnly"], "only oauthAccount is copied, not the whole isolated document")
        XCTAssertNotNil(f.io.backups["Personal"], "the outgoing default login is backed up before replacement")
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Personal"]!).login, try login(a, token: "access-a"))
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, try login(b, token: "access-b"))
        let original = try CLIOwnedLogin(credentials: CLIPrivateFile.read(f.isolatedB.appendingPathComponent(".credentials.json")),
                                         identityDocument: CLIPrivateFile.read(f.isolatedB.appendingPathComponent(".claude.json")))
        XCTAssertEqual(original, try login(b, token: "access-b"), "the account's own directory is never modified")
        let linked = f.home.appendingPathComponent(".claude/projects/-Users-fixture-work/session-1.jsonl")
        let source = f.isolatedB.appendingPathComponent("projects/-Users-fixture-work/session-1.jsonl")
        let left = try FileManager.default.attributesOfItem(atPath: linked.path)[.systemFileNumber] as? NSNumber
        let right = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(left, right, "transcripts are hard-linked, not copied")
        XCTAssertEqual(try Data(contentsOf: f.home.appendingPathComponent(".claude/history.jsonl")), Data("prompt one\n".utf8))
        var info = stat()
        XCTAssertEqual(lstat(f.home.appendingPathComponent(".claude/projects").path, &info), 0)
        XCTAssertNotEqual(info.st_mode & S_IFMT, S_IFLNK, "no symlinked directories")
    }

    func testRoundTripRestoresEachAccountsOwnLogin() async throws {
        let f = try fixture()
        _ = try await follow(f)
        try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[0], profiles: profiles,
                                          home: f.home, repository: f.repository, remote: remote, now: { self.date })
        let live = try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document)
        XCTAssertEqual(live, try login(a, token: "access-a"))
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, try login(b, token: "access-b"))
    }

    func testRenewedIsolatedLoginReplacesStaleBackupButNeverDowngrades() async throws {
        let f = try fixture()
        f.io.backups["Design"] = try CLIBackup.verifiedData(login: login(b, token: "access-b", expired: true), identity: b, now: date.addingTimeInterval(-7200))
        try await CLIDefaultMirror.syncBackup(target: profiles[1], directory: f.isolatedB, io: f.io, now: { self.date }, verify: remote)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, try login(b, token: "access-b"))
        try writeIsolated(f.isolatedB, login(b, token: "access-b", expired: true))
        f.io.backups["Design"] = try CLIBackup.verifiedData(login: login(b, token: "access-b2"), identity: b, now: date)
        try await CLIDefaultMirror.syncBackup(target: profiles[1], directory: f.isolatedB, io: f.io, now: { self.date }, verify: remote)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, try login(b, token: "access-b2"),
                       "a verified newer backup is not replaced by an expired directory copy")
    }

    func testForeignIsolatedLoginIsRefusedBeforeAnyDefaultWrite() async throws {
        let f = try fixture()
        try writeIsolated(f.isolatedB, login(a, token: "access-a"))
        let credentials = f.io.credentials, document = f.io.document
        do { _ = try await follow(f); XCTFail("foreign login") } catch {}
        XCTAssertEqual(f.io.credentials, credentials); XCTAssertEqual(f.io.document, document)
        XCTAssertTrue(f.io.events.isEmpty)
    }

    func testTargetWithoutLoginKeepsPreviousDefaultAndReportsNeedsLogin() async throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.isolatedB)
        let credentials = f.io.credentials, document = f.io.document
        let outcome = try await follow(f)
        XCTAssertEqual(outcome.restoration, .needsLogin)
        XCTAssertEqual(f.io.credentials, credentials); XCTAssertEqual(f.io.document, document)
        XCTAssertNil(f.io.backups["Design"])
    }

    func testBackupWriteFailureLeavesDefaultUntouched() async throws {
        let f = try fixture(); f.io.denyBackupWrite = true
        let credentials = f.io.credentials, document = f.io.document
        do { _ = try await follow(f); XCTFail("backup denied") } catch {}
        XCTAssertEqual(f.io.credentials, credentials); XCTAssertEqual(f.io.document, document)
        XCTAssertFalse(f.io.events.contains("credentials"))
    }

    func testExternalRefreshAfterPreparationStopsWithoutOverwrite() async throws {
        let f = try fixture()
        let io = f.io
        let original = io.credentials
        let credentialsBefore = io.credentials
        // A real CLI can rotate the outgoing login between preparation and the write. The
        // transaction re-reads the owned field and refuses to replace a changed login.
        io.credentialWriter = { [unowned io] data in
            let rotated = try CLIJSON.encode(["accessToken": "access-a2", "refreshToken": "refresh-access-a2", "expiresAt": self.date.addingTimeInterval(3600).timeIntervalSince1970 * 1000])
            io.credentials = try CLIJSON.replacing(io.credentials, key: "claudeAiOauth", with: rotated)
            throw SafetyError("fixture: external writer raced")
        }
        do {
            _ = try await follow(f)
            XCTFail("external refresh must stop the switch")
        } catch {}
        io.credentialWriter = nil
        XCTAssertNotEqual(io.credentials, original)
        XCTAssertEqual(try CLIJSON.object(CLIJSON.field(io.credentials, key: "claudeAiOauth")!)["accessToken"] as? String, "access-a2")
        XCTAssertNotEqual(try CLIJSON.field(io.credentials, key: "claudeAiOauth"), try CLIJSON.field(credentialsBefore, key: "claudeAiOauth"))
        XCTAssertEqual(try CLIOwnedLogin(credentials: io.credentials, identityDocument: io.document).identity?.accountID, a.accountID,
                       "the externally refreshed login is preserved")
        XCTAssertFalse(io.events.contains("marker"))
    }

    func testTranscriptMergeNeverOverwritesDifferingFiles() async throws {
        let f = try fixture()
        let destination = f.home.appendingPathComponent(".claude")
        let project = destination.appendingPathComponent("projects/-Users-fixture-work")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("different\n".utf8).write(to: project.appendingPathComponent("session-1.jsonl"))
        try Data("own history\n".utf8).write(to: destination.appendingPathComponent("history.jsonl"))
        let linked = try CLIDefaultMirror.linkTranscripts(from: f.isolatedB, to: destination)
        XCTAssertEqual(linked, 1)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("session-1.jsonl")), Data("different\n".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("history.jsonl")), Data("own history\n".utf8))
        XCTAssertEqual(try CLIDefaultMirror.linkTranscripts(from: f.isolatedB, to: destination), 0, "idempotent")
    }

    func testTerminalClassificationExcludesOwnHelpersAndCountsOnlySurvivors() {
        let output = """
          101 /Users/test/.local/bin/claude
          102 claude
          103 /Applications/Claude.app/Contents/MacOS/Claude
          104 /opt/homebrew/bin/node
          105 /Users/test/.local/bin/claude-helper
        """
        XCTAssertEqual(CLIDefaultMirror.terminalProcesses(psOutput: output, own: [102]), [101])
        XCTAssertEqual(CLIDefaultMirror.terminalProcesses(psOutput: output, own: []), [101, 102])
    }

    func testOldTerminalsAreReportedNotTerminated() async throws {
        let f = try fixture()
        let outcome = try await follow(f, before: [101, 102], now: [102, 999])
        XCTAssertEqual(outcome.previousTerminals, 1)
        XCTAssertEqual(outcome.restoration, .verifiedLogin)
    }

    func testLegacyProfileNamedDirectoryIsUsedWhenNoBindingExists() async throws {
        let f = try fixture()
        let legacy = f.home.appendingPathComponent(".claude-switcher-cli/Design")
        try FileManager.default.moveItem(at: f.isolatedB, to: legacy)
        let found = try CLIDefaultMirror.isolatedDirectory(identity: b, profile: "Design", home: f.home, repository: f.repository)
        XCTAssertEqual(found?.path, legacy.path)
        let outcome = try await follow(f)
        XCTAssertEqual(outcome.restoration, .verifiedLogin)
        XCTAssertEqual(outcome.linkedTranscripts, 3)
    }

    func testRenewalInDefaultFlowsBackIntoOwnDirectoryBeforeNextSwitch() async throws {
        let f = try fixture()
        _ = try await follow(f)
        // The default store renewed B while B was current; its own directory still has the seed.
        let renewed = try login(b, token: "access-b2")
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: renewed.oauth)
        try CLIDefaultMirror.refreshOwnDirectory(from: f.io, directory: f.isolatedB, expected: b, now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: f.isolatedB, expected: b), renewed)
        XCTAssertEqual(try CLIJSON.object(CLIPrivateFile.read(f.isolatedB.appendingPathComponent(".claude.json"))!)["isolatedOnly"] as? Bool, true)
        // Switch away and back: the renewed credential, not the seed, returns.
        let renewedRemote: (String) async throws -> CLIIdentity = { token in token == "access-b2" ? self.b : try await self.remote(token) }
        try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[0], profiles: profiles,
                                          home: f.home, repository: f.repository, remote: renewedRemote, now: { self.date })
        try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[1], profiles: profiles,
                                          home: f.home, repository: f.repository, remote: renewedRemote, now: { self.date })
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), renewed)
    }

    func testOwnDirectoryIsNotDowngradedByExpiredDefaultOrForeignAccount() async throws {
        let f = try fixture()
        let own = try login(b, token: "access-b")
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: login(b, token: "access-b", expired: true).oauth)
        try CLIDefaultMirror.refreshOwnDirectory(from: f.io, directory: f.isolatedB, expected: b, now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: f.isolatedB, expected: b), own)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: login(a, token: "access-a").oauth)
        try CLIDefaultMirror.refreshOwnDirectory(from: f.io, directory: f.isolatedB, expected: b, now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: f.isolatedB, expected: b), own)
    }
}
