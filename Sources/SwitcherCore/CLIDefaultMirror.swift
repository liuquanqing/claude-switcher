import Foundation
import Darwin

/// The default CLI login is a view of the current account's own login: its isolated directory when
/// one exists, otherwise the verified per-profile backup. Switching copies the owned OAuth field
/// and `oauthAccount` into the default store through the existing transaction, so unrelated
/// settings, MCP logins and every account's original stay untouched. Transcript links are recorded
/// per owner and removed on the next switch; nothing is symlinked and no terminal is stopped.
@MainActor public enum CLIDefaultMirror {
    /// Credential access for an account's own directory. The official CLI may keep the login in a
    /// directory-scoped Keychain item, a private file, or both; the router decides and refuses
    /// conflicts or a denied read.
    public struct DirectoryStore {
        public let directory: URL
        public let readScoped: () throws -> Data?
        public let writeScoped: (Data?) throws -> Void
        public let readDocument: () throws -> Data?
        public let writeDocumentData: (Data?) throws -> Void
        public init(directory: URL, readScoped: @escaping () throws -> Data?, writeScoped: @escaping (Data?) throws -> Void,
                    readDocument: (() throws -> Data?)? = nil, writeDocument: ((Data?) throws -> Void)? = nil) {
            self.directory = directory; self.readScoped = readScoped; self.writeScoped = writeScoped
            self.usesDefaultDocumentIO = readDocument == nil && writeDocument == nil
            self.readDocument = readDocument ?? { try CLIPrivateFile.read(directory.appendingPathComponent(".claude.json")) }
            self.writeDocumentData = writeDocument ?? { try CLIPrivateFile.write($0, to: directory.appendingPathComponent(".claude.json")) }
        }
        @MainActor public func router() -> CLIStoredCredentialRouter {
            CLIStoredCredentialRouter(readPrimary: readScoped, writePrimary: writeScoped,
                readFile: { try CLIPrivateFile.read(directory.appendingPathComponent(".credentials.json")) },
                writeFile: { try CLIPrivateFile.write($0, to: directory.appendingPathComponent(".credentials.json")) })
        }
        public func document() throws -> Data? { try readDocument() }
        public func writeDocument(_ data: Data?) throws { try writeDocumentData(data) }
        /// Compare-and-swap for the real private file; injected stores fall back to their writer.
        public func writeDocument(_ data: Data?, ifUnchangedSince expected: Data?) throws {
            if readDocumentIsPrivateFile { try CLIPrivateFile.write(data, to: directory.appendingPathComponent(".claude.json"), ifUnchangedSince: expected) }
            else { guard try readDocument() == expected else { throw SafetyError("独立目录身份文件在写入前已变化，未覆盖。") }; try writeDocumentData(data) }
        }
        public var readDocumentIsPrivateFile: Bool { usesDefaultDocumentIO }
        public let usesDefaultDocumentIO: Bool
    }

    public struct Outcome: Equatable, Sendable {
        public let restoration: CLIRestoration
        public let linkedTranscripts: Int
        /// Old CLI processes still alive from before the switch. Reported, never terminated.
        public let previousTerminals: Int
        public init(restoration: CLIRestoration, linkedTranscripts: Int = 0, previousTerminals: Int = 0) {
            self.restoration = restoration; self.linkedTranscripts = linkedTranscripts; self.previousTerminals = previousTerminals
        }
    }

    /// Read-only lookup of the account's own directory: the saved binding, the identity-keyed
    /// folder, or the legacy profile-named folder. The default directory is never a source.
    public static func isolatedDirectory(identity: CLIIdentity, profile: String, home: URL,
                                         repository: CLIBindingRepository) throws -> URL? {
        if let binding = try repository.load(identity), binding.choice == .isolated { return binding.directory }
        let keyed = try CLIBinding.directory(for: .isolated, identity: identity, home: home)
        if FileManager.default.fileExists(atPath: keyed.path) {
            try CLIBinding(identity: identity, choice: .isolated, directory: keyed).validate(home: home)
            return keyed
        }
        guard ProfileTransaction.validName(profile) else { return nil }
        let legacy = keyed.deletingLastPathComponent().appendingPathComponent(profile, isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        try CLIBinding(identity: identity, choice: .isolated, directory: legacy).validate(home: home)
        return legacy
    }

    public static func ownedLogin(in store: DirectoryStore, expected: CLIIdentity) throws -> CLIOwnedLogin? {
        let login = try CLIOwnedLogin(credentials: store.router().read(), identityDocument: store.document())
        guard login.hasSecrets else { return nil }
        guard try login.identity?.samePrincipal(as: expected) == true else {
            throw SafetyError("独立目录里的 CLI 登录属于其他账号或组织，未写入默认目录。")
        }
        return login
    }

    /// Refresh the per-profile backup from the account's own directory before it becomes the default.
    /// The directory reading is a candidate: it replaces a verified backup only after its own online
    /// verification, and never replaces a usable or refreshable verified backup with an expired one.
    public struct SyncResult {
        /// Source login observed at the start (nil when no source login), for later change detection.
        public let observed: CLIOwnedLogin?
        /// Backup data written, read back and online-verified in THIS round; only this may be reused.
        public let verifiedRecord: Data?
    }
    @discardableResult
    public static func syncBackup(target: CLIProfileIdentity, store: DirectoryStore?, io: CLICredentialIO,
                                  now: () -> Date = Date.init,
                                  verify: (String) async throws -> CLIIdentity) async throws -> SyncResult {
        guard let expected = target.identity, expected.isComplete, ProfileTransaction.validName(target.name),
              let store else { return SyncResult(observed: nil, verifiedRecord: nil) }
        let login = try ownedLogin(in: store, expected: expected)
        guard let login else { return SyncResult(observed: nil, verifiedRecord: nil) }
        let previous = try io.readBackup(target.name)
        if let previous {
            let backup = try CLIBackup(data: previous)
            guard try backup.login.identity?.samePrincipal(as: expected) == true else {
                throw SafetyError("该档案已有其他账号或组织的 CLI 备份，未覆盖。")
            }
            if backup.login == login { return SyncResult(observed: login, verifiedRecord: nil) }
            if backup.verification != nil {
                if login.usableAccessToken(now: now()) == nil { return SyncResult(observed: login, verifiedRecord: nil) }
                guard CLIBackupFreshness.mayReplace(login, verifiedBackup: backup) else { return SyncResult(observed: login, verifiedRecord: nil) }
            }
        }
        guard let access = login.usableAccessToken(now: now()) else {
            if previous == nil {
                let data = try CLIJSON.encode(["claudeAiOauth": CLIJSON.object(login.oauth!), "oauthAccount": CLIJSON.object(login.metadata!)])
                try io.writeBackup(target.name, data: data)
                guard try io.readBackup(target.name).map({ try CLIJSON.encode(CLIJSON.object($0)) }) == data else {
                    throw SafetyError("CLI 备份回读未通过，默认登录保持原样。")
                }
            }
            return SyncResult(observed: login, verifiedRecord: nil)
        }
        let actual = try await verify(access)
        guard actual.isComplete, actual.samePrincipal(as: expected) else {
            throw SafetyError("独立目录的 CLI 登录与目标账号不符，未更新备份。")
        }
        guard try ownedLogin(in: store, expected: expected) == login else {
            throw SafetyError("独立目录的 CLI 登录在核验期间变化，请重试。")
        }
        let data = try CLIBackup.verifiedData(login: login, identity: actual, now: now())
        guard try io.readBackup(target.name) == previous else { throw SafetyError("CLI 备份在同步期间变化，请重试。") }
        try io.writeBackup(target.name, data: data)
        guard try io.readBackup(target.name).map({ try CLIJSON.encode(CLIJSON.object($0)) }) == data else {
            throw SafetyError("CLI 备份回读未通过，默认登录保持原样。")
        }
        return SyncResult(observed: login, verifiedRecord: data)
    }

    public static func expiry(_ login: CLIOwnedLogin) -> Double? { CLIBackupFreshness.expiry(login) }

    /// While an account is current, the official CLI may renew the default login. Copy it back into
    /// the account's own directory only when the default OAuth and identity block both belong to
    /// that account and the identity was verified online for this exact credential digest. Both
    /// owned fields are written and read back; a failed second write rolls the first one back.
    public static func refreshOwnDirectory(from io: CLICredentialIO, store: DirectoryStore, expected: CLIIdentity,
                                           verified: CLIVerification?, now: () -> Date = Date.init) throws {
        guard let verified, verified.version == 1, verified.identity.samePrincipal(as: expected) else { return }
        let live = try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
        guard live.hasSecrets, live.digest == verified.digest, try live.identity?.samePrincipal(as: expected) == true,
              let own = try ownedLogin(in: store, expected: expected), own != live else { return }
        if own.usableAccessToken(now: now()) != nil, live.usableAccessToken(now: now()) == nil { return }
        // "Newer" must be provable: the default credential's own expiry is later than the directory's.
        guard let ownExpiry = expiry(own), let liveExpiry = expiry(live), liveExpiry > ownExpiry else { return }
        let router = store.router()
        let credentials = try router.read()
        let document = try store.document()
        guard try CLIOwnedLogin(credentials: credentials, identityDocument: document) == own else { return }
        let newCredentials = try CLIJSON.replacing(credentials, key: "claudeAiOauth", with: live.oauth)
        try router.write(newCredentials)
        var documentBefore: Data?
        var documentWritten = false
        do {
            // Re-read the document after the credential write: the terminal may have changed
            // project settings or its identity meanwhile; only oauthAccount is replaced.
            let latest = try store.document()
            guard try CLIJSON.field(latest, key: "oauthAccount") == own.metadata else {
                throw SafetyError("独立目录的身份在同步期间变化，未覆盖。")
            }
            documentBefore = latest
            let newDocument = try CLIJSON.replacing(latest, key: "oauthAccount", with: live.metadata)
            try store.writeDocument(newDocument, ifUnchangedSince: latest); documentWritten = true
            guard try CLIJSON.field(router.read(), key: "claudeAiOauth") == live.oauth,
                  try CLIJSON.field(store.document(), key: "oauthAccount") == live.metadata else {
                throw SafetyError("独立目录回读未通过，登录同步未确认。")
            }
        } catch {
            var restored = true
            if documentWritten, let documentBefore {
                do {
                    let current = try store.document()
                    if try CLIJSON.field(current, key: "oauthAccount") == live.metadata {
                        try store.writeDocument(CLIJSON.replacing(current, key: "oauthAccount", with: own.metadata), ifUnchangedSince: current)
                    }
                } catch { restored = false }
            }
            do {
                let current = try router.read()
                if try CLIJSON.field(current, key: "claudeAiOauth") == live.oauth {
                    try router.write(CLIJSON.replacing(current, key: "claudeAiOauth", with: own.oauth))
                }
            } catch { restored = false }
            let confirmed = (try? CLIOwnedLogin(credentials: router.read(), identityDocument: store.document())) == own
            guard restored, confirmed else {
                throw SafetyError("独立目录同步失败且回滚未确认，请保留现场并停止切换。")
            }
            throw error
        }
    }

    /// Transcripts are deliberately NOT shared between the default directory and an account's own
    /// directory. Hard links would let one account's terminal read and append another account's
    /// history; the official CLI keeps each directory's history separate and that is the safe
    /// default. Only the login follows the account.
    public static func linkTranscripts(from source: URL, to destination: URL, owner: String, journalURL: URL) throws -> Int { 0 }

    /// Pure classification of `ps -axo pid=,comm=` output. `own` are the CLI helpers this app
    /// spawned for status or renewal; they are not user terminals. This never signals a process.
    public static func terminalProcesses(psOutput: String, own: Set<Int32>) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(trimmed[..<split]), !own.contains(pid) else { return nil }
            let command = trimmed[split...].trimmingCharacters(in: .whitespaces)
            return command == "claude" || command.hasSuffix("/claude") ? pid : nil
        }
    }

    /// After the desktop moved: put the target's login into the default store, keep the outgoing
    /// account's newest default login in its backup, and share the target's transcripts. A target
    /// without any saved login leaves the previous default login in place and still backs it up.
    public static func follow(transaction: CLITransaction, target: CLIProfileIdentity, profiles: [CLIProfileIdentity],
                              home: URL, repository: CLIBindingRepository,
                              storeFor: (URL) -> DirectoryStore,
                              journalURL: URL,
                              remote: @escaping (String) async throws -> CLIIdentity,
                              now: () -> Date = Date.init,
                              contextIsCurrent: () async throws -> Bool = { true },
                              terminalsBefore: () -> [Int32] = { [] },
                              terminalsNow: () -> [Int32] = { [] }) async throws -> Outcome {
        let before = terminalsBefore()
        guard try await contextIsCurrent() else { throw SafetyError("桌面账号已变化，未修改终端登录。") }
        let source = try isolatedDirectory(identity: target.identity!, profile: target.name, home: home, repository: repository).map(storeFor)
        let sync = try await syncBackup(target: target, store: source, io: transaction.io, now: now, verify: remote)
        let observed = sync.observed
        guard try await contextIsCurrent() else { throw SafetyError("桌面账号已变化，未修改终端登录。") }
        if let record = sync.verifiedRecord { transaction.preverified[target.name] = record }
        let plan = try await transaction.prepare(target: target, profiles: profiles, remote: remote)
        // Compare against what was observed at sync time, not against the backup (which may
        // legitimately be newer than an expired source).
        if let source, let expected = target.identity, try ownedLogin(in: source, expected: expected) != observed {
            let saved = try await syncBackup(target: target, store: source, io: transaction.io, now: now, verify: remote)
            let persisted = try transaction.io.readBackup(target.name).map { try CLIBackup(data: $0).login }
            throw SafetyError(saved.verifiedRecord != nil && persisted == saved.observed
                ? "独立目录的登录在核验期间更新，已保存最新版本；请再切换一次以使用它。"
                : "独立目录的登录在核验期间变化，未修改默认登录；请再切换一次。")
        }
        guard try await contextIsCurrent() else { throw SafetyError("桌面账号已变化，未修改终端登录。") }
        if plan.restoration == .needsLogin {
            try transaction.persistOutgoing(plan)
            return Outcome(restoration: .needsLogin, previousTerminals: before.filter { Set(terminalsNow()).contains($0) }.count)
        }
        // The follow path promises an online-verified login; a merely stored backup is not enough.
        guard plan.restoration == .verifiedLogin, plan.desired.usableAccessToken(now: now()) != nil else {
            try transaction.persistOutgoing(plan)
            throw SafetyError("目标终端登录本次未能在线核验，默认登录保持原样；请在终端里确认登录后重试。")
        }
        try transaction.persistOutgoing(plan)
        guard try await contextIsCurrent() else { throw SafetyError("桌面账号已变化，未修改终端登录。") }
        // Last asynchronous step is done: re-read the source once more immediately before commit.
        if let source, let expected = target.identity, try ownedLogin(in: source, expected: expected) != observed {
            throw SafetyError("独立目录的登录在提交前变化，未修改默认登录；请再切换一次。")
        }
        let restoration = try transaction.apply(plan, requireUsableLogin: true)
        let alive = Set(terminalsNow())
        return Outcome(restoration: restoration, linkedTranscripts: 0, previousTerminals: before.filter { alive.contains($0) }.count)
    }
}
