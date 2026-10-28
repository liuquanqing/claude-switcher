import Foundation
import CryptoKit
import Darwin

public enum SessionTransferDisk {
    static var fm: FileManager { .default }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func segment(_ value: String) -> Bool { ProfileTransaction.validName(value) && !value.contains("\\") }
    static func name(_ value: String) -> Bool { segment(value) && value.hasPrefix("local_") && value.hasSuffix(".json") }
    static func identity(_ url: URL, directory: Bool) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw SessionTransferFailure("路径缺失或不可读取，未修改会话。") }
        let kind = info.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(directory ? S_IFDIR : S_IFREG) else { throw SessionTransferFailure("路径不是普通\(directory ? "目录" : "文件")，不跟随符号链接。") }
        return "\(info.st_dev):\(info.st_ino)"
    }
    static func data(_ url: URL) throws -> Data {
        _ = try identity(url, directory: false)
        return try Data(contentsOf: url)
    }
    static func optionalData(_ url: URL) throws -> Data? {
        do { return try data(url) }
        catch {
            var info = stat()
            if lstat(url.path, &info) != 0 && errno == ENOENT { return nil }
            throw error
        }
    }
    static func directories(_ url: URL) throws -> [URL] {
        _ = try identity(url, directory: true)
        return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { (try? identity($0, directory: true)) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func marker(_ endpoint: SessionTransferEndpoint) throws -> String? {
        guard let marker = endpoint.marker else {
            guard endpoint.expectedMarker == nil else { throw SessionTransferFailure("档案绑定无效。") }
            return nil
        }
        let bytes = try data(marker)
        guard let expected = endpoint.expectedMarker, let actual = String(data: bytes, encoding: .utf8),
              actual.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            throw SessionTransferFailure("账号档案已变化，请重新选择会话。")
        }
        return hash(bytes)
    }
    static func scope(_ space: SessionTransferSpace) throws -> SessionTransferScope {
        guard segment(space.account), segment(space.organization) else { throw SessionTransferFailure("会话空间标识无效。") }
        let root = space.endpoint.root, sessions = root.appendingPathComponent("claude-code-sessions")
        let account = sessions.appendingPathComponent(space.account)
        let rootID = try identity(root, directory: true)
        _ = try identity(sessions, directory: true)
        return try SessionTransferScope(endpointID: space.endpoint.id, account: space.account, organization: space.organization,
                                        rootIdentity: rootID, accountIdentity: identity(account, directory: true),
                                        directoryIdentity: identity(space.directory, directory: true))
    }
    static func json(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SessionTransferFailure("会话索引不是JSON对象。") }
        return value
    }
    static func encode(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func ensurePrivateDirectory(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) { _ = try identity(url, directory: true) }
        else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    /// A same-directory stage and exclusive link publish new indexes without overwriting
    /// an index another writer created. Replacement is atomic per file, not per batch.
    public static func write(_ bytes: Data, _ url: URL, _ mode: SessionTransferWriteMode) throws {
        _ = try identity(url.deletingLastPathComponent(), directory: true)
        if mode == .replace {
            if let _ = try optionalData(url) { _ = try identity(url, directory: false) }
            try bytes.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        let stage = url.deletingLastPathComponent().appendingPathComponent(".transfer-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try bytes.write(to: stage, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
        try fm.linkItem(at: stage, to: url)
    }
}
