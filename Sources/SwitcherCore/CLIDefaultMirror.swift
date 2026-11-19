import Foundation
import Darwin

/// The default CLI login is a view of the current account's own login: its isolated directory when
/// one exists, otherwise the verified per-profile backup. Switching copies the owned OAuth field
/// and `oauthAccount` into the default store through the existing transaction, so unrelated
/// settings, MCP logins and every account's original stay untouched. Transcripts are shared by
/// hard link; nothing is symlinked and no running terminal is stopped.
@MainActor public enum CLIDefaultMirror {
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

    public static func ownedLogin(in directory: URL, expected: CLIIdentity) throws -> CLIOwnedLogin? {
        let login = try CLIOwnedLogin(credentials: CLIPrivateFile.read(directory.appendingPathComponent(".credentials.json")),
                                      identityDocument: CLIPrivateFile.read(directory.appendingPathComponent(".claude.json")))
        guard login.hasSecrets else { return nil }
        guard try login.identity?.samePrincipal(as: expected) == true else {
            throw SafetyError("独立目录里的 CLI 登录属于其他账号或组织，未写入默认目录。")
        }
        return login
    }

    /// Refresh the per-profile backup from the account's own directory before it becomes the default.
    /// A newer backup (for example a renewal already verified by the watcher) is never downgraded.
    public static func syncBackup(target: CLIProfileIdentity, directory: URL?, io: CLICredentialIO,
                                  now: () -> Date = Date.init,
                                  verify: ((String) async throws -> CLIIdentity)? = nil) async throws {
        guard let expected = target.identity, expected.isComplete, ProfileTransaction.validName(target.name),
              let directory, let login = try ownedLogin(in: directory, expected: expected) else { return }
        let previous = try io.readBackup(target.name)
        if let previous {
            let backup = try CLIBackup(data: previous)
            guard try backup.login.identity?.samePrincipal(as: expected) == true else {
                throw SafetyError("该档案已有其他账号或组织的 CLI 备份，未覆盖。")
            }
            if backup.login == login { return }
            if backup.verification != nil, backup.login.hasRefreshToken,
               login.usableAccessToken(now: now()) == nil, backup.login.usableAccessToken(now: now()) != nil { return }
        }
        let data: Data
        if let access = login.usableAccessToken(now: now()), let verify {
            let actual = try await verify(access)
            guard actual.isComplete, actual.samePrincipal(as: expected) else {
                throw SafetyError("独立目录的 CLI 登录与目标账号不符，未更新备份。")
            }
            guard try ownedLogin(in: directory, expected: expected) == login else {
                throw SafetyError("独立目录的 CLI 登录在核验期间变化，请重试。")
            }
            data = try CLIBackup.verifiedData(login: login, identity: actual, now: now())
        } else {
            data = try CLIJSON.encode(["claudeAiOauth": CLIJSON.object(login.oauth!), "oauthAccount": CLIJSON.object(login.metadata!)])
        }
        guard try io.readBackup(target.name) == previous else { throw SafetyError("CLI 备份在同步期间变化，请重试。") }
        try io.writeBackup(target.name, data: data)
        guard try io.readBackup(target.name).map({ try CLIJSON.encode(CLIJSON.object($0)) }) == data else {
            throw SafetyError("CLI 备份回读未通过，默认登录保持原样。")
        }
    }

    /// While an account is current, the official CLI may renew the default login. Copy that newer
    /// owned login back into the account's own directory so the next switch restores it, not the seed.
    /// Only the two owned fields are written; an expired default never replaces a usable own login.
    public static func refreshOwnDirectory(from io: CLICredentialIO, directory: URL, expected: CLIIdentity,
                                           now: () -> Date = Date.init) throws {
        let live = try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
        guard live.hasSecrets, try live.identity?.samePrincipal(as: expected) == true,
              let own = try ownedLogin(in: directory, expected: expected), own != live else { return }
        if own.usableAccessToken(now: now()) != nil, live.usableAccessToken(now: now()) == nil { return }
        let credentials = directory.appendingPathComponent(".credentials.json")
        let document = directory.appendingPathComponent(".claude.json")
        try CLIPrivateFile.write(CLIJSON.replacing(CLIPrivateFile.read(credentials), key: "claudeAiOauth", with: live.oauth), to: credentials)
        try CLIPrivateFile.write(CLIJSON.replacing(CLIPrivateFile.read(document), key: "oauthAccount", with: live.metadata), to: document)
    }

    /// Share transcripts so the account keeps its context in the default directory and in its own.
    /// Only regular files with the same name are linked; differing files are left alone. A running
    /// CLI that replaces a transcript atomically simply breaks the link for later writes.
    public static func linkTranscripts(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        var linked = 0
        func regular(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
        }
        func plainDirectory(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
        }
        func merge(_ from: URL, _ to: URL) throws {
            guard plainDirectory(from) else { return }
            if !fm.fileExists(atPath: to.path) {
                try fm.createDirectory(at: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            guard plainDirectory(to) else { return }
            for entry in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                let target = to.appendingPathComponent(entry.lastPathComponent)
                if plainDirectory(entry) { try merge(entry, target); continue }
                guard regular(entry), !fm.fileExists(atPath: target.path) else { continue }
                do { try fm.linkItem(at: entry, to: target); linked += 1 }
                catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
            }
        }
        let history = source.appendingPathComponent("history.jsonl")
        let destinationHistory = destination.appendingPathComponent("history.jsonl")
        if regular(history), !fm.fileExists(atPath: destinationHistory.path) {
            try fm.linkItem(at: history, to: destinationHistory); linked += 1
        }
        try merge(source.appendingPathComponent("projects"), destination.appendingPathComponent("projects"))
        return linked
    }

    /// Pure classification of `ps -axo pid=,comm=` output. `own` are the CLI helpers this app
    /// spawned for status or renewal; they are not user terminals.
    public static func terminalProcesses(psOutput: String, own: Set<Int32>) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]), !own.contains(pid) else { return nil }
            let command = fields[1].trimmingCharacters(in: .whitespaces)
            return command == "claude" || command.hasSuffix("/claude") ? pid : nil
        }
    }

    /// After the desktop moved: put the target's login into the default store, keep the outgoing
    /// account's newest default login in its backup, and share the target's transcripts.
    /// A target without any saved login leaves the previous default login in place; the caller
    /// reports the mismatch instead of signing the terminal out.
    public static func follow(transaction: CLITransaction, target: CLIProfileIdentity, profiles: [CLIProfileIdentity],
                              home: URL, repository: CLIBindingRepository,
                              remote: @escaping (String) async throws -> CLIIdentity,
                              now: () -> Date = Date.init,
                              terminalsBefore: () -> [Int32] = { [] },
                              terminalsNow: () -> [Int32] = { [] }) async throws -> Outcome {
        let before = terminalsBefore()
        let source = try isolatedDirectory(identity: target.identity!, profile: target.name, home: home, repository: repository)
        try await syncBackup(target: target, directory: source, io: transaction.io, now: now, verify: remote)
        let plan = try await transaction.prepare(target: target, profiles: profiles, remote: remote)
        // Never sign the terminal out: without a target login the previous default stays and the
        // caller shows the mismatch.
        if plan.restoration == .needsLogin {
            return Outcome(restoration: .needsLogin, previousTerminals: before.filter { Set(terminalsNow()).contains($0) }.count)
        }
        try transaction.persistOutgoing(plan)
        let restoration = try transaction.apply(plan)
        var linked = 0
        if let source, restoration != .needsLogin {
            linked = (try? linkTranscripts(from: source, to: home.appendingPathComponent(".claude", isDirectory: true))) ?? 0
        }
        let alive = Set(terminalsNow())
        return Outcome(restoration: restoration, linkedTranscripts: linked, previousTerminals: before.filter { alive.contains($0) }.count)
    }
}
