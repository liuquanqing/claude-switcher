import Foundation
import Security
import SwitcherCore

@MainActor final class NativeCLIStorage: CLICredentialIO {
    private let identityURL: URL
    private let markerURL: URL
    init(identity: URL = claudeJSON, marker: URL = cliCurrentFile) { identityURL = identity; markerURL = marker }
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
        try readKeychain(service: service, account: account).map(CLIJSON.encode)
    }
    func readCredentials() throws -> Data? { try keychain(cliService, NSUserName()) }
    func writeCredentials(_ data: Data?) throws {
        if let data { try writeKeychain(service: cliService, account: NSUserName(), json: CLIJSON.object(data)) }
        else {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: cliService, kSecAttrAccount as String: NSUserName()]
            let status = SecItemDelete(query as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw err("CLI 还原失败（状态 \(status)）。") }
        }
    }
    func readIdentityDocument() throws -> Data? { try readFile(identityURL) }
    func writeIdentityDocument(_ data: Data?) throws { try writeFile(data, path: identityURL) }
    func readBackup(_ profile: String) throws -> Data? { try keychain(switcherService, "cli-" + profile) }
    func writeBackup(_ profile: String, data: Data) throws {
        try writeKeychain(service: switcherService, account: "cli-" + profile, json: CLIJSON.object(data))
    }
    func readMarker() throws -> String? {
        guard let data = try readFile(markerURL) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw err("CLI 关联标记无法读取。") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func writeMarker(_ value: String?) throws { try writeFile(value.map { Data($0.utf8) }, path: markerURL) }
}
