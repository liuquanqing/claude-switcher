import Foundation
import Security
import SwitcherCore

@MainActor final class NativeCLIStorage: CLICredentialIO {
    private let identityURL: URL
    private let markerURL: URL
    private let readSecret: (String, String) throws -> Data?
    private let writeSecret: (String, String, Data?) throws -> Void
    private let credentials: CLIStoredCredentialRouter
    private let backupPresence: (String, String) throws -> Bool
    private let audit: CredentialReadAudit
    var readSummary: [CredentialReadSummary] { audit.summary }
    init(identity: URL = claudeJSON, marker: URL = cliCurrentFile, allowInteraction: Bool = true,
         credentialFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"),
         secretReader: ((String, String) throws -> Data?)? = nil,
         secretWriter: ((String, String, Data?) throws -> Void)? = nil,
         interactionReader: ((String, String, Bool) throws -> Data?)? = nil) {
        identityURL = identity; markerURL = marker
        let audit = CredentialReadAudit(); self.audit = audit
        let accessReader = interactionReader ?? { service, account, interaction in
            try readKeychain(service: service, account: account, allowInteraction: interaction).map(CLIJSON.encode)
        }
        var interactionAttempted = Set<String>()
        let reader = secretReader ?? { service, account in
            // Fresh comparisons still read the real store. Only the first read
            // of each object in this operation may solicit system UI.
            let mayAsk = allowInteraction && interactionAttempted.insert(service + "\u{0}" + account).inserted
            do {
                let data = try accessReader(service, account, mayAsk)
                audit.record(service: service, interactive: mayAsk, result: .success(data))
                return data
            } catch {
                audit.record(service: service, interactive: mayAsk, result: .failure(error))
                throw error
            }
        }
        let writer = secretWriter ?? Self.writeNativeSecret
        backupPresence = secretReader == nil && interactionReader == nil
            ? { service, account in try KeychainReadAccess.contains(service: service, account: account) }
            : { service, account in try reader(service, account) != nil }
        readSecret = reader; writeSecret = writer
        let account = NSUserName()
        credentials = CLIStoredCredentialRouter(readPrimary: { try reader(cliService, account) },
            writePrimary: { try writer(cliService, account, $0) },
            readFile: { try CLIPrivateFile.read(credentialFile) },
            writeFile: { try CLIPrivateFile.write($0, to: credentialFile) })
    }
    private func readFile(_ path: URL) throws -> Data? {
        do { return try Data(contentsOf: path) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
    }
    private func writeFile(_ data: Data?, path: URL) throws {
        if let data {
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } else {
            do { try FileManager.default.removeItem(at: path) }
            catch let e as CocoaError where e.code == .fileNoSuchFile { return }
        }
    }
    private func keychain(_ service: String, _ account: String) throws -> Data? {
        try readSecret(service, account)
    }
    func readCredentials() throws -> Data? { try credentials.read() }
    func writeCredentials(_ data: Data?) throws { try credentials.write(data) }
    private static func writeNativeSecret(_ service: String, _ account: String, _ data: Data?) throws {
        if let data { try writeKeychain(service: service, account: account, json: CLIJSON.object(data)) }
        else {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
            let status = SecItemDelete(query as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw err("CLI 还原失败（状态 \(status)）。") }
        }
    }
    func readIdentityDocument() throws -> Data? { try readFile(identityURL) }
    func writeIdentityDocument(_ data: Data?) throws { try writeFile(data, path: identityURL) }
    func readBackup(_ profile: String) throws -> Data? { try keychain(switcherService, "cli-" + profile) }
    func containsBackup(_ profile: String) throws -> Bool { try backupPresence(switcherService, "cli-" + profile) }
    func writeBackup(_ profile: String, data: Data) throws {
        try writeSecret(switcherService, "cli-" + profile, data)
    }
    func readMarker() throws -> String? {
        guard let data = try readFile(markerURL) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw err("CLI 关联标记无法读取。") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func writeMarker(_ value: String?) throws { try writeFile(value.map { Data($0.utf8) }, path: markerURL) }
}
