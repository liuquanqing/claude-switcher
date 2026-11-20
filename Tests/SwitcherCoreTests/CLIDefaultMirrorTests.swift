import XCTest
@testable import SwitcherCore

@MainActor private final class MirrorIO: CLICredentialIO {
    var credentials: Data?, document: Data?, marker: String?
    var backups: [String: Data] = [:]
    var events: [String] = []
    var denyBackupWrite = false
    var credentialWriter: ((Data?) throws -> Void)?
    var backupWriter: ((String, Data) throws -> Void)?
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
        if let backupWriter { try backupWriter(profile, data) } else { backups[profile] = data }
    }
    func readMarker() throws -> String? { marker }
    func writeMarker(_ value: String?) throws { events.append("marker"); marker = value }
}

@MainActor private final class ScopedSecrets {
    var items: [String: Data] = [:]
    var denyRead = false
    var denyDocumentWrite = false
    var denyWrite = false
    func store(_ directory: URL) -> CLIDefaultMirror.DirectoryStore {
        let key = directory.path
        return CLIDefaultMirror.DirectoryStore(directory: directory,
            readScoped: { [self] in if denyRead { throw SafetyError("fixture: keychain denied") }; return items[key] },
            writeScoped: { [self] data in
                if denyWrite { throw SafetyError("fixture: keychain write denied") }
                items[key] = data
            })
    }
}

@MainActor final class CLIDefaultMirrorTests: FixtureTest {
    private let secrets = ScopedSecrets()
    private func store(_ directory: URL) -> CLIDefaultMirror.DirectoryStore { secrets.store(directory) }
    private func journal(_ home: URL) -> URL { home.appendingPathComponent("state/cli-transcript-links.json") }
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var a: CLIIdentity { CLIIdentity(accountID: "account-a", organizationID: "org-a", email: "a@example.test") }
    private var b: CLIIdentity { CLIIdentity(accountID: "account-b", organizationID: "org-b", email: "b@example.test") }
    private var profiles: [CLIProfileIdentity] { [.init(name: "Personal", identity: a), .init(name: "Design", identity: b)] }
    private func login(_ identity: CLIIdentity, token: String, expired: Bool = false, lifetime: TimeInterval = 3600) throws -> CLIOwnedLogin {
        CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken": token, "refreshToken": "refresh-" + token,
                                                 "expiresAt": date.addingTimeInterval(expired ? -60 : lifetime).timeIntervalSince1970 * 1000]),
                      metadata: try CLIJSON.encode(["accountUuid": identity.accountID!, "organizationUuid": identity.organizationID!, "emailAddress": identity.email!]))
    }
    private func remote(_ token: String) async throws -> CLIIdentity {
        if ["access-a", "access-a2", "access-a2", "access-a3"].contains(token) { return a }
        if token == "access-b" || token == "access-b2" { return b }
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
                                          home: fixture.home, repository: fixture.repository, storeFor: store, journalURL: journal(fixture.home),
                                          remote: remote, now: { self.date },
                                          terminalsBefore: { before }, terminalsNow: { now })
    }

    func testFollowTransfersLoginAndPreservesHistoriesAndSettings() async throws {
        let f = try fixture()
        let defaultHistory = f.home.appendingPathComponent(".claude/history.jsonl")
        let isolatedHistory = f.isolatedB.appendingPathComponent("history.jsonl")
        let defaultBytes = Data("default history fixture\n".utf8)
        let isolatedBytes = try Data(contentsOf: isolatedHistory)
        try defaultBytes.write(to: defaultHistory)
        let outcome = try await follow(f)
        XCTAssertEqual(outcome.restoration, .verifiedLogin)
        XCTAssertEqual(outcome.linkedTranscripts, 0, "histories are never shared between directories")
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
        XCTAssertFalse(original.hasSecrets)
        XCTAssertNil(original.metadata)
        XCTAssertEqual(try CLIJSON.object(CLIPrivateFile.read(f.isolatedB.appendingPathComponent(".claude.json"))!)["isolatedOnly"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".claude/projects").path), "no history is linked into the default directory")
        XCTAssertEqual(try Data(contentsOf: defaultHistory), defaultBytes)
        XCTAssertEqual(try Data(contentsOf: isolatedHistory), isolatedBytes)
    }

    func testRoundTripRestoresEachAccountsOwnLogin() async throws {
        let f = try fixture()
        _ = try await follow(f)
        try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[0], profiles: profiles,
                                          home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home), remote: remote, now: { self.date })
        let live = try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document)
        XCTAssertEqual(live, try login(a, token: "access-a"))
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, try login(b, token: "access-b"))
    }

    func testRenewedIsolatedLoginReplacesStaleBackupButNeverDowngrades() async throws {
        let f = try fixture()
        f.io.backups["Design"] = try CLIBackup.verifiedData(login: login(b, token: "access-b", expired: true), identity: b, now: date.addingTimeInterval(-7200))
        try await CLIDefaultMirror.syncBackup(target: profiles[1], store: store(f.isolatedB), io: f.io, now: { self.date }, verify: remote)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, try login(b, token: "access-b"))
        try writeIsolated(f.isolatedB, login(b, token: "access-b", expired: true))
        f.io.backups["Design"] = try CLIBackup.verifiedData(login: login(b, token: "access-b2"), identity: b, now: date)
        try await CLIDefaultMirror.syncBackup(target: profiles[1], store: store(f.isolatedB), io: f.io, now: { self.date }, verify: remote)
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

    func testTerminalClassificationExcludesOwnHelpersAndCountsOnlySurvivors() {
        let output = """
          101 /Users/test/.local/bin/claude
          102 claude
          103 /Applications/Claude.app/Contents/MacOS/Claude
          104 /opt/homebrew/bin/node
          105 /Users/test/.local/bin/claude-helper
          106 /Users/test/.local/share/claude/versions/2.1.328
        """
        XCTAssertEqual(CLIDefaultMirror.terminalProcesses(psOutput: output, own: [102]), [101])
        XCTAssertEqual(CLIDefaultMirror.terminalProcesses(psOutput: output, own: []), [101, 102])
        let versions = URL(fileURLWithPath: "/Users/test/.local/share/claude/versions")
        XCTAssertEqual(CLIDefaultMirror.terminalProcesses(psOutput: output, own: [102], nativeVersions: versions), [101, 106])
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
        XCTAssertEqual(outcome.linkedTranscripts, 0, "histories are never shared between directories")
    }

    func testRenewalInDefaultFlowsBackIntoOwnDirectoryBeforeNextSwitch() async throws {
        let f = try fixture()
        _ = try await follow(f)
        XCTAssertNil(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b))
        let renewed = try login(b, token: "access-b2", lifetime: 7200)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: renewed.oauth)
        f.io.document = try CLIJSON.replacing(f.io.document, key: "oauthAccount", with: renewed.metadata)
        XCTAssertNil(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b))
        XCTAssertEqual(try CLIJSON.object(CLIPrivateFile.read(f.isolatedB.appendingPathComponent(".claude.json"))!)["isolatedOnly"] as? Bool, true)
        // Switch away and back: the renewed credential, not the seed, returns.
        let renewedRemote: (String) async throws -> CLIIdentity = { token in token == "access-b2" ? self.b : try await self.remote(token) }
        try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[0], profiles: profiles,
                                          home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home), remote: renewedRemote, now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), renewed)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, renewed)
        try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[1], profiles: profiles,
                                          home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home), remote: renewedRemote, now: { self.date })
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), renewed)
        XCTAssertNil(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b))
    }

    func testOwnDirectoryIsNotDowngradedByExpiredDefaultOrForeignAccount() async throws {
        let f = try fixture()
        let own = try login(b, token: "access-b")
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: login(b, token: "access-b", expired: true).oauth)
        try CLIDefaultMirror.refreshOwnDirectory(from: f.io, store: store(f.isolatedB), expected: b,
            verified: CLIVerification(login: try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), identity: b, checkedAt: date), now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), own)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: login(a, token: "access-a").oauth)
        try CLIDefaultMirror.refreshOwnDirectory(from: f.io, store: store(f.isolatedB), expected: b,
            verified: CLIVerification(login: try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), identity: b, checkedAt: date), now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), own)
    }

    // MARK: Codex review regressions

    func testReverseSyncRefusesForeignOAuthEvenWhenIdentityBlockMatches() async throws {
        let f = try fixture()
        // Default store holds A's OAuth but B's identity block (a real external-switch race).
        let mixed = CLIOwnedLogin(oauth: try login(a, token: "access-a").oauth, metadata: try login(b, token: "access-b").metadata)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: mixed.oauth)
        f.io.document = try CLIJSON.replacing(f.io.document, key: "oauthAccount", with: mixed.metadata)
        let own = try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b)
        // No verification exists for this digest: nothing is written.
        try CLIDefaultMirror.refreshOwnDirectory(from: f.io, store: store(f.isolatedB), expected: b, verified: nil, now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), own)
        // Even a verification for B cannot bless A's token: the digest differs.
        try CLIDefaultMirror.refreshOwnDirectory(from: f.io, store: store(f.isolatedB), expected: b,
            verified: CLIVerification(login: try login(b, token: "access-b2"), identity: b, checkedAt: date), now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), own)
    }

    func testReverseSyncRollsBackCredentialWhenIdentityWriteFails() async throws {
        let f = try fixture()
        let renewed = try login(b, token: "access-b2", lifetime: 7200)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: renewed.oauth)
        f.io.document = try CLIJSON.replacing(f.io.document, key: "oauthAccount", with: renewed.metadata)
        let own = try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b)
        // A store whose identity document cannot be written: the credential write must be rolled back.
        let document = f.isolatedB.appendingPathComponent(".claude.json")
        let saved = try CLIPrivateFile.read(document)
        try FileManager.default.removeItem(at: document)
        try FileManager.default.createDirectory(at: document, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: document); try? CLIPrivateFile.write(saved, to: document) }
        do {
            try CLIDefaultMirror.refreshOwnDirectory(from: f.io, store: store(f.isolatedB), expected: b,
                verified: CLIVerification(login: renewed, identity: b, checkedAt: date), now: { self.date })
            XCTFail("document write must fail")
        } catch {}
        try FileManager.default.removeItem(at: document)
        try CLIPrivateFile.write(saved, to: document)
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), own, "credential rolled back, no mixed state")
    }

    func testScopedKeychainLoginIsReadAndUpdatedNotTheStaleFile() async throws {
        let f = try fixture()
        let renewed = try login(b, token: "access-b2", lifetime: 7200)
        try FileManager.default.removeItem(at: f.isolatedB.appendingPathComponent(".credentials.json"))
        secrets.items[f.isolatedB.path] = try CLIJSON.replacing(nil, key: "claudeAiOauth", with: renewed.oauth)
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), renewed)
        let outcome = try await follow(f)
        XCTAssertEqual(outcome.restoration, .verifiedLogin)
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), renewed)
        // A denied scoped read is never treated as an empty login.
        secrets.denyRead = true
        do { _ = try await follow(f); XCTFail("denied read") } catch {}
    }

    func testVerifiedBackupIsNeverDowngradedByAnExpiredOrUnverifiedCandidate() async throws {
        let f = try fixture()
        let verified = try CLIBackup.verifiedData(login: login(b, token: "access-b2"), identity: b, now: date)
        f.io.backups["Design"] = verified
        try writeIsolated(f.isolatedB, login(b, token: "access-b", expired: true))
        try await CLIDefaultMirror.syncBackup(target: profiles[1], store: store(f.isolatedB), io: f.io, now: { self.date }, verify: remote)
        XCTAssertEqual(f.io.backups["Design"], verified)
        // Same expiry: kept even if it would verify. A later-expiry candidate that fails verification is not saved.
        try writeIsolated(f.isolatedB, login(b, token: "access-b"))
        try await CLIDefaultMirror.syncBackup(target: profiles[1], store: store(f.isolatedB), io: f.io, now: { self.date }, verify: { _ in throw SafetyError("offline") })
        XCTAssertEqual(f.io.backups["Design"], verified)
        try writeIsolated(f.isolatedB, login(b, token: "access-b", lifetime: 9000))
        do {
            try await CLIDefaultMirror.syncBackup(target: profiles[1], store: store(f.isolatedB), io: f.io, now: { self.date }, verify: { _ in throw SafetyError("offline") })
            XCTFail("verify must fail")
        } catch {}
        XCTAssertEqual(f.io.backups["Design"], verified)
        try await CLIDefaultMirror.syncBackup(target: profiles[1], store: store(f.isolatedB), io: f.io, now: { self.date }, verify: remote)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, try login(b, token: "access-b", lifetime: 9000))
    }

    func testSourceRenewalDuringVerificationIsSavedAndSwitchStopsBeforeCommit() async throws {
        let f = try fixture()
        var calls = 0
        let credentials = f.io.credentials
        do {
            _ = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[1], profiles: profiles,
                home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home),
                remote: { token in
                    calls += 1
                    // The source is renewed after the backup sync verified it, while the transaction
                    // verifies the outgoing default login.
                    if calls == 2 { try self.writeIsolated(f.isolatedB, self.login(self.b, token: "access-b2", lifetime: 9000)) }
                    return try await self.remote(token)
                }, now: { self.date })
            XCTFail("must stop")
        } catch {}
        XCTAssertEqual(f.io.credentials, credentials, "default untouched")
        XCTAssertGreaterThanOrEqual(calls, 3)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Design"]!).login, try login(b, token: "access-b2", lifetime: 9000), "newest source saved")
        XCTAssertFalse(f.io.events.contains("marker"))
    }
    func testContextChangeBeforeCommitStopsWithoutWritingDefault() async throws {
        let f = try fixture()
        let credentials = f.io.credentials
        var current = true
        do {
            _ = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[1], profiles: profiles,
                home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home),
                remote: { token in current = false; return try await self.remote(token) }, now: { self.date },
                contextIsCurrent: { current })
            XCTFail("context changed")
        } catch {}
        XCTAssertEqual(f.io.credentials, credentials)
        XCTAssertFalse(f.io.events.contains("marker"))
    }

    func testNeedsLoginStillBacksUpTheOutgoingDefault() async throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.isolatedB)
        let outcome = try await follow(f)
        XCTAssertEqual(outcome.restoration, .needsLogin)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Personal"]!).login, try login(a, token: "access-a"))
    }

    func testTerminalParsingHandlesTabsAndDoesNotSignal() {
        let output = "  101\t/Users/x/.local/bin/claude\n  102  claude\n  103 /Applications/Claude.app/Contents/MacOS/Claude\n"
        XCTAssertEqual(CLIDefaultMirror.terminalProcesses(psOutput: output, own: []), [101, 102])
    }

    func testExpiredSourceWithValidBackupDoesNotTriggerFalseRenewalLoop() async throws {
        let f = try fixture()
        f.io.backups["Design"] = try CLIBackup.verifiedData(login: login(b, token: "access-b2", lifetime: 7200), identity: b, now: date)
        try writeIsolated(f.isolatedB, login(b, token: "access-b", expired: true))
        let outcome = try await follow(f)
        XCTAssertEqual(outcome.restoration, .verifiedLogin, "a valid backup switches even when the source is expired")
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document).usableAccessToken(now: date), "access-b2")
    }

    func testOlderExpiryCandidateNeverReplacesNewerVerifiedBackup() async throws {
        let f = try fixture()
        let newer = try CLIBackup.verifiedData(login: login(b, token: "access-b2", lifetime: 7200), identity: b, now: date)
        f.io.backups["Design"] = newer
        try writeIsolated(f.isolatedB, login(b, token: "access-b", lifetime: 3600))
        try await CLIDefaultMirror.syncBackup(target: profiles[1], store: store(f.isolatedB), io: f.io, now: { self.date }, verify: remote)
        XCTAssertEqual(f.io.backups["Design"], newer)
    }

    func testReverseSyncSkipsDefaultWithEarlierExpiryEvenWhenVerified() async throws {
        let f = try fixture()
        let older = try login(b, token: "access-b2", lifetime: 1800)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: older.oauth)
        f.io.document = try CLIJSON.replacing(f.io.document, key: "oauthAccount", with: older.metadata)
        try CLIDefaultMirror.refreshOwnDirectory(from: f.io, store: store(f.isolatedB), expected: b,
            verified: CLIVerification(login: older, identity: b, checkedAt: date), now: { self.date })
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), try login(b, token: "access-b"))
    }

    func testStoredOnlyBackupIsNotCommittedWithoutFreshOnlineVerification() async throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.isolatedB)
        // A backup whose access token expired but has a refresh token and a historic proof.
        f.io.backups["Design"] = try CLIBackup.verifiedData(login: login(b, token: "access-b", expired: true), identity: b, now: date.addingTimeInterval(-7200))
        let credentials = f.io.credentials
        do { _ = try await follow(f); XCTFail("must require fresh verification") } catch {}
        XCTAssertEqual(f.io.credentials, credentials)
        XCTAssertNotNil(f.io.backups["Personal"], "outgoing still backed up")
    }

    func testTerminalPathWithSpacesIsCounted() {
        XCTAssertEqual(CLIDefaultMirror.terminalProcesses(psOutput: "  101 /Users/test/Local Tools/claude\n", own: []), [101])
    }

    func testSameAccountSwitchUsesNewerVerifiedBackupAndNeverWritesItBackOlder() async throws {
        let f = try fixture()
        // Default holds A; A's own directory was renewed and saved as a newer verified backup.
        let newer = try login(a, token: "access-a2", lifetime: 9000)
        f.io.backups["Personal"] = try CLIBackup.verifiedData(login: newer, identity: a, now: date)
        let outcome = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[0], profiles: profiles,
            home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home), remote: remote, now: { self.date })
        XCTAssertEqual(outcome.restoration, .verifiedLogin)
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), newer)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Personal"]!).login, newer, "the older default never overwrites the newer backup")
    }

    func testPassiveBackupWithoutVerifyKeepsNewerVerifiedBackupAndReverifiesIdenticalUnverifiedOne() async throws {
        let io = MirrorIO()
        let newer = try login(a, token: "access-a2", lifetime: 9000)
        io.credentials = try CLIJSON.replacing(nil, key: "claudeAiOauth", with: newer.oauth)
        io.document = try CLIJSON.replacing(nil, key: "oauthAccount", with: newer.metadata)
        io.backups["Personal"] = try CLIBackup.verifiedData(login: login(a, token: "access-a", lifetime: 12000), identity: a, now: date)
        let kept = io.backups["Personal"]
        let result = try await CLICurrentBackup.save(target: profiles[0], io: io, now: { self.date }, contextIsCurrent: { true })
        XCTAssertEqual(result, .upToDate); XCTAssertEqual(io.backups["Personal"], kept)
        // Identical login saved without proof earlier: a later gated verification adds the proof.
        io.backups["Personal"] = try CLIJSON.encode(["claudeAiOauth": CLIJSON.object(newer.oauth!), "oauthAccount": CLIJSON.object(newer.metadata!)])
        let verified = try await CLICurrentBackup.save(target: profiles[0], io: io, now: { self.date }, contextIsCurrent: { true }, gate: { true }, verify: { _ in self.a })
        XCTAssertEqual(verified, .saved)
        XCTAssertEqual(try CLIBackup(data: io.backups["Personal"]!).trustedIdentity(), a)
    }

    func testSourceChangeAfterLastAsyncCheckStopsBeforeApply() async throws {
        let f = try fixture()
        let credentials = f.io.credentials
        var checks = 0
        do {
            _ = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[1], profiles: profiles,
                home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home), remote: remote, now: { self.date },
                contextIsCurrent: { checks += 1; if checks == 3 { try self.writeIsolated(f.isolatedB, self.login(self.b, token: "access-b2", lifetime: 9000)) }; return true })
            XCTFail("must stop")
        } catch {}
        XCTAssertEqual(f.io.credentials, credentials)
    }

    func testSameAccountNewerBackupCommitsWithRealClockAndExpiredDefault() async throws {
        let f = try fixture()
        // Default A expired; A's own directory renewed and saved as a newer verified backup.
        let now = Date()
        func live(_ identity: CLIIdentity, _ token: String, _ seconds: TimeInterval) throws -> CLIOwnedLogin {
            CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken": token, "refreshToken": "refresh-" + token, "expiresAt": now.addingTimeInterval(seconds).timeIntervalSince1970 * 1000]),
                          metadata: try CLIJSON.encode(["accountUuid": identity.accountID!, "organizationUuid": identity.organizationID!, "emailAddress": identity.email!]))
        }
        let expiredDefault = try live(a, "access-a", -60)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: expiredDefault.oauth)
        let newer = try live(a, "access-a2", 9000)
        // A's own directory holds the renewal; this round verifies it and writes the slot once.
        let isolatedA = try CLIBinding.directory(for: .isolated, identity: a, home: f.home)
        try writeIsolated(isolatedA, newer)
        var verifiedTokens: [String] = []
        let trackingRemote: (String) async throws -> CLIIdentity = { token in verifiedTokens.append(token); return try await self.remote(token) }
        let writesBefore = f.io.events.filter { $0 == "backup:Personal" }.count
        let clock: () -> Date = { Date() }
        let outcome = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: clock), target: profiles[0], profiles: profiles,
            home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home), remote: trackingRemote, now: clock)
        XCTAssertEqual(outcome.restoration, .verifiedLogin)
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), newer)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Personal"]!).login, newer)
        XCTAssertFalse(verifiedTokens.contains("access-a"), "the expired old default is never sent for verification")
        XCTAssertEqual(verifiedTokens.filter { $0 == "access-a2" }.count, 1, "the winning login is verified exactly once this round")
        XCTAssertEqual(f.io.events.filter { $0 == "backup:Personal" }.count - writesBefore, 1, "the slot is written once")
    }

    func testManualRecoveryPreparationAllowsNewerSameAccountBackupOverExpiredDefault() async throws {
        let io = MirrorIO()
        let expired = try login(a, token: "access-a", expired: true)
        io.credentials = try CLIJSON.replacing(nil, key: "claudeAiOauth", with: expired.oauth)
        io.document = try CLIJSON.replacing(nil, key: "oauthAccount", with: expired.metadata)
        io.backups["Personal"] = try CLIBackup.verifiedData(login: login(a, token: "access-a2", lifetime: 9000), identity: a, now: date)
        let outcome = try await CLIBackupRecovery.prepare(target: profiles[0], io: io, now: { self.date }, requireUsableLogin: true,
            renew: { _, _ in XCTFail("usable newer backup needs no renewal"); throw SafetyError("x") }, remote: remote)
        XCTAssertEqual(outcome, .notNeeded)
    }

    func testDocumentWriteRaceIsAbortedByCompareAndSwap() async throws {
        let f = try fixture()
        let renewed = try login(b, token: "access-b2", lifetime: 7200)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: renewed.oauth)
        f.io.document = try CLIJSON.replacing(f.io.document, key: "oauthAccount", with: renewed.metadata)
        let document = f.isolatedB.appendingPathComponent(".claude.json")
        // Real private-file store; the scoped keychain write hook simulates the terminal saving the
        // document after the credential write but before the document commit.
        let file = f.isolatedB.appendingPathComponent(".credentials.json")
        let racing = CLIDefaultMirror.DirectoryStore(directory: f.isolatedB,
            readScoped: { try CLIPrivateFile.read(file) },
            writeScoped: { data in
                try CLIPrivateFile.write(data, to: file)
                var latest = try CLIJSON.object(CLIPrivateFile.read(document)!)
                latest["projects"] = ["raced": true]
                try CLIPrivateFile.write(CLIJSON.encode(latest), to: document)
            })
        do {
            try CLIDefaultMirror.refreshOwnDirectory(from: f.io, store: racing, expected: b,
                verified: CLIVerification(login: renewed, identity: b, checkedAt: date), now: { self.date })
            XCTFail("race must abort")
        } catch {}
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(f.isolatedB), expected: b), try login(b, token: "access-b"), "credential rolled back")
        let after = try CLIJSON.object(CLIPrivateFile.read(document)!)
        XCTAssertEqual(after["projects"] as? [String: Bool], ["raced": true])
        XCTAssertEqual(try CLIIdentity.metadata(CLIJSON.field(CLIPrivateFile.read(document), key: "oauthAccount"))?.accountID, b.accountID)
    }

    func testOfflineBackupNeverReplacesVerifiedSlotWithMixedIdentity() async throws {
        let io = MirrorIO()
        // OAuth already B, identity block still A (external sign-in in progress).
        let mixed = CLIOwnedLogin(oauth: try login(b, token: "access-b", lifetime: 99999).oauth, metadata: try login(a, token: "access-a").metadata)
        io.credentials = try CLIJSON.replacing(nil, key: "claudeAiOauth", with: mixed.oauth)
        io.document = try CLIJSON.replacing(nil, key: "oauthAccount", with: mixed.metadata)
        let verified = try CLIBackup.verifiedData(login: login(a, token: "access-a"), identity: a, now: date)
        io.backups["Personal"] = verified
        let result = try await CLICurrentBackup.save(target: profiles[0], io: io, now: { self.date }, contextIsCurrent: { true })
        XCTAssertEqual(result, .upToDate)
        XCTAssertEqual(io.backups["Personal"], verified)
    }

    func testReverseSyncPreservesConcurrentDocumentChangesAndRollsBackByField() async throws {
        let f = try fixture()
        let renewed = try login(b, token: "access-b2", lifetime: 7200)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: renewed.oauth)
        f.io.document = try CLIJSON.replacing(f.io.document, key: "oauthAccount", with: renewed.metadata)
        let document = f.isolatedB.appendingPathComponent(".claude.json")
        // A store whose credential write succeeds and then the terminal updates the document's
        // project settings before the identity write; the identity write must fail and roll back.
        let base = store(f.isolatedB)
        // File-only store (scoped Keychain empty). The document read simulates the terminal
        // updating settings and identity right after the credential write; the identity write fails.
        var reads = 0
        let racingRead: () throws -> Data? = {
            reads += 1
            let data = try CLIPrivateFile.read(document)
            if reads >= 3 {
                var latest = try CLIJSON.object(data!)
                latest["projects"] = ["changed": true]
                latest["oauthAccount"] = try CLIJSON.object(self.login(self.a, token: "access-a").metadata!)
                let encoded = try CLIJSON.encode(latest)
                try CLIPrivateFile.write(encoded, to: document)
                return encoded
            }
            return data
        }
        let racingStore = CLIDefaultMirror.DirectoryStore(directory: f.isolatedB, readScoped: { nil }, writeScoped: { _ in throw SafetyError("unused") },
            readDocument: racingRead, writeDocument: { _ in throw SafetyError("fixture: document write denied") })
        do {
            try CLIDefaultMirror.refreshOwnDirectory(from: f.io, store: racingStore, expected: b,
                verified: CLIVerification(login: renewed, identity: b, checkedAt: date), now: { self.date })
            XCTFail("identity changed concurrently")
        } catch {}
        // Credential rolled back to B's seed; the terminal's concurrent document (A identity +
        // changed settings) is left exactly as the terminal wrote it, never overwritten.
        XCTAssertEqual(try CLIJSON.field(CLIPrivateFile.read(f.isolatedB.appendingPathComponent(".credentials.json")), key: "claudeAiOauth"),
                       try login(b, token: "access-b").oauth)
        let after = try CLIJSON.object(CLIPrivateFile.read(document)!)
        XCTAssertEqual(after["projects"] as? [String: Bool], ["changed": true], "concurrent settings kept")
        XCTAssertEqual(try CLIIdentity.metadata(CLIJSON.field(CLIPrivateFile.read(document), key: "oauthAccount"))?.accountID, a.accountID, "foreign identity kept, not overwritten")
    }

    func testHistoricProofWithoutSourceIsNotReusedAsThisRoundsVerification() async throws {
        let f = try fixture()
        // Default A expired, no isolated directory, only a historic verified backup with later expiry.
        let now = Date()
        let expired = CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken": "access-a", "refreshToken": "r", "expiresAt": now.addingTimeInterval(-60).timeIntervalSince1970 * 1000]),
                                    metadata: try login(a, token: "access-a").metadata)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: expired.oauth)
        let newer = CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken": "access-a2", "refreshToken": "r", "expiresAt": now.addingTimeInterval(9000).timeIntervalSince1970 * 1000]),
                                  metadata: try login(a, token: "access-a2").metadata)
        f.io.backups["Personal"] = try CLIBackup.verifiedData(login: newer, identity: a, now: now.addingTimeInterval(-3600))
        var tokens: [String] = []
        let outcome = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io), target: profiles[0], profiles: profiles,
            home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home),
            remote: { t in tokens.append(t); return try await self.remote(t) })
        XCTAssertEqual(outcome.restoration, .verifiedLogin)
        XCTAssertEqual(tokens, ["access-a2"], "the backup is verified online this round, not trusted from history")
    }

    func testOutgoingSlotChangedByAnotherWriterStopsCommit() async throws {
        let f = try fixture()
        let credentials = f.io.credentials
        var checks = 0
        do {
            _ = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[1], profiles: profiles,
                home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home),
                remote: { token in
                    checks += 1
                    // The other writer lands while the target login is being verified online.
                    if checks == 2 {
                        f.io.backups["Personal"] = try CLIBackup.verifiedData(login: self.login(self.a, token: "access-a2", lifetime: 99999), identity: self.a, now: self.date)
                    }
                    return try await self.remote(token)
                }, now: { self.date })
            XCTFail("must stop")
        } catch {}
        XCTAssertEqual(f.io.credentials, credentials)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Personal"]!).login, try login(a, token: "access-a2", lifetime: 99999))
    }

    func testCrossAccountTargetSlotWrittenOnce() async throws {
        let f = try fixture()
        let before = f.io.events.filter { $0 == "backup:Design" }.count
        _ = try await follow(f)
        XCTAssertEqual(f.io.events.filter { $0 == "backup:Design" }.count - before, 1)
    }

    func testTargetExpiringDuringLastAsyncCheckIsNotCommitted() async throws {
        let f = try fixture()
        var clock = date
        let credentials = f.io.credentials
        // B's login expires while the final desktop re-check runs.
        let expiring = CLIOwnedLogin(oauth: try CLIJSON.encode(["accessToken": "access-b", "refreshToken": "r", "expiresAt": date.addingTimeInterval(30).timeIntervalSince1970 * 1000]),
                                     metadata: try login(b, token: "access-b").metadata)
        try writeIsolated(f.isolatedB, expiring)
        var checks = 0
        do {
            _ = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { clock }), target: profiles[1], profiles: profiles,
                home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home), remote: remote, now: { clock },
                contextIsCurrent: { checks += 1; if checks == 4 { clock = self.date.addingTimeInterval(60) }; return true })
            XCTFail("expired at commit")
        } catch {}
        XCTAssertEqual(f.io.credentials, credentials)
        XCTAssertEqual(f.io.marker, "Personal")
    }

    func testTargetSlotChangedWhileWritingOutgoingIsNotOverwritten() async throws {
        let f = try fixture()
        // B backup is an older unverified record; the transaction would upgrade it.
        f.io.backups["Design"] = try CLIJSON.encode(["claudeAiOauth": CLIJSON.object(login(b, token: "access-b").oauth!), "oauthAccount": CLIJSON.object(login(b, token: "access-b").metadata!)])
        // No isolated source: the transaction itself upgrades the pending target slot.
        try FileManager.default.removeItem(at: f.isolatedB)
        let newerByOther = try CLIBackup.verifiedData(login: login(b, token: "access-b2", lifetime: 99999), identity: b, now: date)
        let credentials = f.io.credentials
        var wroteConcurrentBackup = false
        // The other writer lands while the outgoing default is being verified online, i.e. after
        // prepare captured the target slot but before persistOutgoing writes it.
        do {
            _ = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[1], profiles: profiles,
                home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home),
                remote: { token in
                    if token == "access-a" {
                        f.io.backups["Design"] = newerByOther
                        wroteConcurrentBackup = true
                    }
                    return try await self.remote(token)
                }, now: { self.date })
            XCTFail("must stop")
        } catch {}
        XCTAssertTrue(wroteConcurrentBackup)
        XCTAssertEqual(f.io.credentials, credentials)
        XCTAssertEqual(f.io.backups["Design"], newerByOther)
    }

    func testCrossAccountTargetVerifiedOnceAndWrittenOnce() async throws {
        let f = try fixture()
        var tokens: [String] = []
        let before = f.io.events.filter { $0 == "backup:Design" }.count
        _ = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: profiles[1], profiles: profiles,
            home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home),
            remote: { t in tokens.append(t); return try await self.remote(t) }, now: { self.date })
        XCTAssertEqual(tokens.filter { $0 == "access-b" }.count, 1)
        XCTAssertEqual(f.io.events.filter { $0 == "backup:Design" }.count - before, 1)
    }

    func testIdentityDocumentCreationDoesNotClobberConcurrentFile() throws {
        let home = try directory("home2/.claude")
        let document = home.appendingPathComponent(".claude.json")
        // expected nil (absent); a concurrent writer creates it before commit -> abort.
        let data = try CLIJSON.encode(["oauthAccount": ["accountUuid": "x"]])
        try CLIPrivateFile.writeDocument(data, to: document, ifUnchangedSince: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        // 0644 owner file is accepted for identity documents.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path)
        let existing = try CLIPrivateFile.readDocument(document)
        let updated = try CLIJSON.encode(["oauthAccount": ["accountUuid": "y"]])
        try CLIPrivateFile.writeDocument(updated, to: document, ifUnchangedSince: existing)
        XCTAssertEqual(try CLIPrivateFile.readDocument(document), updated)
        // Stale expectation aborts.
        do { try CLIPrivateFile.writeDocument(data, to: document, ifUnchangedSince: existing); XCTFail("stale") } catch {}
        XCTAssertEqual(try CLIPrivateFile.readDocument(document), updated)
    }

    // MARK: Single holder: the outgoing default login returns to its own directory before the switch

    /// Default holds A renewed in place (later expiry); A's own directory still holds the seed.
    private func renewedDefaultA(_ f: (home: URL, io: MirrorIO, repository: CLIBindingRepository, isolatedB: URL)) throws -> CLIOwnedLogin {
        let renewed = try login(a, token: "access-a2", lifetime: 7200)
        f.io.credentials = try CLIJSON.replacing(f.io.credentials, key: "claudeAiOauth", with: renewed.oauth)
        f.io.document = try CLIJSON.replacing(f.io.document, key: "oauthAccount", with: renewed.metadata)
        return renewed
    }
    private func isolatedA(_ home: URL) throws -> URL { try CLIBinding.directory(for: .isolated, identity: a, home: home) }

    func testSwitchAwayWritesRenewedDefaultBackIntoOutgoingOwnDirectoryBeforeCommit() async throws {
        let f = try fixture()
        let ownA = try isolatedA(f.home)
        try writeIsolated(ownA, login(a, token: "access-a"), extra: ["isolatedOnly": true])
        let renewed = try renewedDefaultA(f)
        _ = try await follow(f)
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(ownA), expected: a), renewed,
                       "the outgoing account's own directory receives the renewed default login")
        XCTAssertEqual(try CLIJSON.object(CLIPrivateFile.read(ownA.appendingPathComponent(".claude.json"))!)["isolatedOnly"] as? Bool, true,
                       "only the owned login fields are replaced in the own directory")
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Personal"]!).login, renewed)
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), try login(b, token: "access-b"))
    }

    func testFailedWriteBackStopsBeforeDefaultChanges() async throws {
        let f = try fixture()
        let ownA = try isolatedA(f.home)
        try FileManager.default.createDirectory(at: ownA, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let seed = try login(a, token: "access-a")
        secrets.items[ownA.path] = try CLIJSON.replacing(nil, key: "claudeAiOauth", with: seed.oauth)
        try CLIPrivateFile.write(CLIJSON.encode(["oauthAccount": CLIJSON.object(seed.metadata!)]), to: ownA.appendingPathComponent(".claude.json"))
        let renewed = try renewedDefaultA(f)
        secrets.denyWrite = true
        do { _ = try await follow(f); XCTFail("a failed write-back must stop the switch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未能写回")) }
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), renewed,
                       "the default keeps the outgoing login when it could not be returned")
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(ownA), expected: a), seed)
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Personal"]!).login, renewed, "the backup is written first")
    }

    func testFailedDefaultCommitReturnsBothDirectoryLoginsToTheirPreviousState() async throws {
        let fixture = try fixture()
        let outgoingDirectory = try isolatedA(fixture.home)
        let outgoingBefore = try login(a, token: "access-a")
        let incomingBefore = try login(b, token: "access-b")
        try writeIsolated(outgoingDirectory, outgoingBefore)
        let renewed = try renewedDefaultA(fixture)
        fixture.io.credentialWriter = { _ in throw SafetyError("fixture refused default write") }
        do {
            _ = try await follow(fixture)
            XCTFail("default write should fail")
        } catch {}
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(outgoingDirectory), expected: a), outgoingBefore)
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(fixture.isolatedB), expected: b), incomingBefore)
        XCTAssertEqual(try CLITransaction(io: fixture.io).readOwned(), renewed)
        XCTAssertEqual(try CLIBackup(data: fixture.io.backups["Personal"]!).login, renewed)
    }

    func testWriteBackKeepsOwnDirectoryWithLaterExpiry() async throws {
        let f = try fixture()
        let ownA = try isolatedA(f.home)
        let newer = try login(a, token: "access-a3", lifetime: 9000)
        try writeIsolated(ownA, newer)
        _ = try await follow(f)
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(ownA), expected: a), newer,
                       "an own directory renewed later is never replaced by an older default")
        XCTAssertEqual(try CLIOwnedLogin(credentials: f.io.credentials, identityDocument: f.io.document), try login(b, token: "access-b"))
    }

    func testNoTargetLoginKeepsDefaultAsOnlyActiveStoreAndSavesBackup() async throws {
        let f = try fixture()
        let ownA = try isolatedA(f.home)
        try writeIsolated(ownA, login(a, token: "access-a"))
        let renewed = try renewedDefaultA(f)
        let c = CLIIdentity(accountID: "account-c", organizationID: "org-c", email: "c@example.test")
        let all = profiles + [.init(name: "Business", identity: c)]
        let outcome = try await CLIDefaultMirror.follow(transaction: CLITransaction(io: f.io, now: { self.date }), target: all[2], profiles: all,
            home: f.home, repository: f.repository, storeFor: store, journalURL: journal(f.home), remote: remote, now: { self.date })
        XCTAssertEqual(outcome.restoration, .needsLogin)
        XCTAssertEqual(try CLIDefaultMirror.ownedLogin(in: store(ownA), expected: a), try login(a, token: "access-a"))
        XCTAssertEqual(try CLIBackup(data: f.io.backups["Personal"]!).login, renewed)
        XCTAssertEqual(try CLITransaction(io: f.io).readOwned(), renewed)
    }
}
