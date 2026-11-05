import Foundation
import CryptoKit

public enum CLIBindingChoice: String, Codable, Sendable { case defaultLogin, isolated }

public struct CLIBinding: Codable, Equatable, Sendable {
    public let identity: CLIIdentity
    public let choice: CLIBindingChoice
    public let directory: URL
    public init(identity: CLIIdentity, choice: CLIBindingChoice, directory: URL) {
        self.identity = identity; self.choice = choice; self.directory = directory
    }
    public static func key(_ identity: CLIIdentity) throws -> String {
        guard identity.isComplete else { throw SafetyError("桌面账号身份尚未确认，不能建立 CLI 关联。") }
        func canonical(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed
        }
        let normalized = canonical(identity.accountID!) + "\n" + canonical(identity.organizationID!)
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func directory(for choice: CLIBindingChoice, identity: CLIIdentity, home: URL) throws -> URL {
        if choice == .defaultLogin { return home.appendingPathComponent(".claude", isDirectory: true) }
        return home.appendingPathComponent(".claude-switcher-cli", isDirectory: true)
            .appendingPathComponent(try key(identity), isDirectory: true)
    }
    public func validate(home: URL) throws {
        let expected = try Self.directory(for: choice, identity: identity, home: home).standardizedFileURL
        let legacyOwnedDirectory = choice == .isolated
            && directory.deletingLastPathComponent().standardizedFileURL.path == home.appendingPathComponent(".claude-switcher-cli").standardizedFileURL.path
            && ProfileTransaction.validName(directory.lastPathComponent)
            && FileManager.default.fileExists(atPath: directory.path)
        guard directory.isFileURL, directory.standardizedFileURL.path == expected.path || legacyOwnedDirectory else {
            throw SafetyError("CLI 关联目录无法确认，原登录和历史保持原样。")
        }
        let paths = choice == .defaultLogin ? [directory] : [directory.deletingLastPathComponent(), directory]
        for path in paths {
            do {
                let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw SafetyError("CLI 目录不是普通目录，未打开或迁移登录。")
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
        }
    }
}

/// Own metadata only: no tokens, login backups or session contents are stored here.
public struct CLIBindingRepository {
    public let file: URL
    public let home: URL
    public init(file: URL, home: URL) { self.file = file; self.home = home }
    private func read() throws -> [String: CLIBinding] {
        do { return try JSONDecoder().decode([String: CLIBinding].self, from: Data(contentsOf: file)) }
        catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile { return [:] }
    }
    public func load(_ identity: CLIIdentity) throws -> CLIBinding? {
        guard let result = try read()[CLIBinding.key(identity)] else { return nil }
        guard result.identity.samePrincipal(as: identity) else { throw SafetyError("CLI 关联身份不一致，未打开。") }
        try result.validate(home: home)
        return result
    }
    public func save(_ binding: CLIBinding) throws {
        try binding.validate(home: home)
        var bindings = try read()
        bindings[try CLIBinding.key(binding.identity)] = binding
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(bindings).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public enum CLIBindingStatus: Equatable, Sendable { case matched, notLoggedIn, different, unconfirmed }
public enum CLIBindingPolicy {
    public static func assess(_ report: CLIReportedStatus, binding: CLIBinding, metadata: CLIIdentity?) -> CLIBindingStatus {
        guard report.usesConfigurationDirectory(binding.directory) else { return .unconfirmed }
        guard report.loggedIn else { return ["none", "claude.ai"].contains(report.authMethod) ? .notLoggedIn : .unconfirmed }
        guard report.authMethod == "claude.ai" else { return .unconfirmed }
        let identity = report.savedRecord(matching: metadata) ?? report.identity
        guard identity.isComplete else { return .unconfirmed }
        return identity.samePrincipal(as: binding.identity) ? .matched : .different
    }
}
