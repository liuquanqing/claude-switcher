import Foundation
import Darwin

/// Private JSON files used by the default CLI. No login values appear in errors.
public enum CLIPrivateFile {
    private static func check(_ info: stat, directory: Bool = false) throws {
        guard (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              info.st_uid == getuid(), directory || (info.st_mode & 0o077) == 0 else {
            throw SafetyError("CLI 登录文件的类型、归属或权限不符合要求，未修改登录。")
        }
    }
    private static func checkParent(_ url: URL) throws {
        var info = stat()
        guard lstat(url.deletingLastPathComponent().path, &info) == 0 else {
            throw SafetyError("CLI 登录文件目录无法确认，未修改登录。")
        }
        try check(info, directory: true)
    }
    public static func read(_ url: URL) throws -> Data? {
        // An existing symlinked .claude directory must not redirect this adapter.
        var parent = stat()
        if lstat(url.deletingLastPathComponent().path, &parent) == 0 { try check(parent, directory: true) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw SafetyError("无法读取 CLI 登录文件；未将读取失败当作空登录。")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SafetyError("CLI 登录文件无法核对。") }
        try check(info)
        return try handle.readToEnd() ?? Data()
    }
    /// Identity documents (~/.claude.json) are owner-owned regular files that the CLI may keep at
    /// 0644; credentials stay strict. Reads never follow symlinks.
    public static func readDocument(_ url: URL) throws -> Data? {
        var parent = stat()
        if lstat(url.deletingLastPathComponent().path, &parent) == 0 { try check(parent, directory: true) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw SafetyError("无法读取 CLI 身份文件；未将读取失败当作空文件。")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw SafetyError("CLI 身份文件的类型或归属不符合要求，未修改。")
        }
        return try handle.readToEnd() ?? Data()
    }
    public static func writeDocument(_ data: Data?, to url: URL, ifUnchangedSince expected: Data?) throws {
        try checkParent(url)
        guard try readDocument(url) == expected else { throw SafetyError("CLI 身份文件在写入前已被其他程序更新，未覆盖。") }
        guard let data else {
            if unlink(url.path) != 0 && errno != ENOENT { throw SafetyError("CLI 身份文件无法更新。") }
            return
        }
        try stage(data, to: url, expecting: expected, expectAbsent: expected == nil, document: true)
    }
    /// Replace only when the file still equals `expected`; a concurrent writer aborts this write.
    public static func write(_ data: Data?, to url: URL, ifUnchangedSince expected: Data?) throws {
        try checkParent(url)
        guard try read(url) == expected else { throw SafetyError("CLI 登录文件在写入前已被其他程序更新，未覆盖。") }
        guard let data else {
            if unlink(url.path) != 0 && errno != ENOENT { throw SafetyError("CLI 登录文件无法更新。") }
            return
        }
        try stage(data, to: url, expecting: expected, expectAbsent: expected == nil, document: false)
    }
    public static func write(_ data: Data?, to url: URL) throws {
        try checkParent(url)
        _ = try read(url)
        guard let data else {
            if unlink(url.path) != 0 && errno != ENOENT { throw SafetyError("CLI 登录文件无法更新。") }
            return
        }
        try stage(data, to: url, expecting: nil, expectAbsent: false, document: false)
    }
    private static func stage(_ data: Data, to url: URL, expecting expected: Data?, expectAbsent: Bool, document: Bool) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".cli-login-" + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SafetyError("无法创建私有 CLI 登录临时文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(temporary.path) }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if expectAbsent {
                // Atomic exclusive commit: a file created concurrently is never replaced.
                guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw SafetyError("CLI 文件在提交前已被其他程序创建，未覆盖。")
                }
            } else {
                if let expected {
                    let current = document ? try readDocument(url) : try read(url)
                    guard current == expected else { throw SafetyError("CLI 文件在提交前已被其他程序更新，未覆盖。") }
                }
                guard rename(temporary.path, url.path) == 0 else { throw SafetyError("CLI 登录文件提交失败。") }
            }
        } catch { throw SafetyError("CLI 登录文件写入失败，未确认同步完成。") }
    }
}

/// Pin the storage route for one transaction. A simultaneous CLI refresh or login
/// is a real writer: re-read before replacing owned OAuth, never copy a whole store.
@MainActor public final class CLIStoredCredentialRouter {
    public enum Kind: String { case keychain, file, mirrored }
    private struct Observation: Equatable { let primary: Data?; let file: Data? }
    private let readPrimary: () throws -> Data?
    private let writePrimary: (Data?) throws -> Void
    private let readFile: () throws -> Data?
    private let writeFile: (Data?) throws -> Void
    private let writeFileIfUnchanged: ((Data?, Data?) throws -> Void)?
    private let writePrimaryIfUnchanged: ((Data?, Data?, Bool) throws -> Void)?
    public private(set) var kind: Kind?
    private var observed: Observation?

    public init(readPrimary: @escaping () throws -> Data?, writePrimary: @escaping (Data?) throws -> Void,
                readFile: @escaping () throws -> Data?, writeFile: @escaping (Data?) throws -> Void,
                writeFileIfUnchanged: ((Data?, Data?) throws -> Void)? = nil,
                writePrimaryIfUnchanged: ((Data?, Data?, Bool) throws -> Void)? = nil) {
        self.readPrimary = readPrimary; self.writePrimary = writePrimary
        self.readFile = readFile; self.writeFile = writeFile; self.writeFileIfUnchanged = writeFileIfUnchanged
        self.writePrimaryIfUnchanged = writePrimaryIfUnchanged
    }
    /// Snapshots for conditional writes come from the pinned observation, not extra store reads.
    private func writeCredentialFile(_ data: Data?) throws {
        if let writeFileIfUnchanged { try writeFileIfUnchanged(data, observed?.file) } else { try writeFile(data) }
    }
    private func writeCredentialPrimary(_ data: Data?) throws {
        if let writePrimaryIfUnchanged { try writePrimaryIfUnchanged(data, observed?.primary, observed?.primary == nil) } else { try writePrimary(data) }
    }
    private func normalized(_ data: Data?) throws -> Data? { try data.map { try CLIJSON.encode(CLIJSON.object($0)) } }
    private func containers() throws -> Observation {
        // A denied/locked Keychain is not proof that the primary login is absent.
        try Observation(primary: normalized(readPrimary()), file: normalized(readFile()))
    }
    private func oauth(_ data: Data?) throws -> Data? { try CLIJSON.field(data, key: "claudeAiOauth") }
    private func route(_ value: Observation) throws -> Kind {
        let primary = try oauth(value.primary), file = try oauth(value.file)
        if primary != nil && file != nil {
            guard primary == file else { throw SafetyError("钥匙串与凭据文件保存了不同的 CLI 登录，未备份或覆盖；请先在官方 CLI 确认登录来源。") }
            return .mirrored
        }
        if primary != nil { return .keychain }
        if file != nil {
            guard value.primary == nil else {
                throw SafetyError("钥匙串有现存条目，但订阅登录只在文件中；来源无法确认，未改写任一存储。")
            }
            return .file
        }
        // Clearing an owned login must not change where a later rollback writes.
        return kind ?? (value.primary != nil || value.file == nil ? .keychain : .file)
    }
    public func read() throws -> Data? {
        let value = try containers(), selected = try route(value)
        guard kind == nil || kind == selected else { throw SafetyError("CLI 登录存储在操作期间变化，未改写登录。") }
        kind = selected; observed = value
        return selected == .file ? value.file : value.primary
    }
    public func write(_ data: Data?) throws {
        guard let before = observed, let kind else { throw SafetyError("CLI 登录尚未读取，未写入。") }
        guard try containers() == before else { throw SafetyError("CLI 登录在写入前变化，未覆盖新登录。") }
        let desired = try oauth(data)
        func replacing(_ value: Data?) throws -> Data? { try CLIJSON.replacing(value, key: "claudeAiOauth", with: desired) }
        switch kind {
        case .keychain: try writeCredentialPrimary(replacing(before.primary))
        case .file: try writeCredentialFile(replacing(before.file))
        case .mirrored:
            var primaryAttempted = false, fileAttempted = false
            do {
                primaryAttempted = true; try writeCredentialPrimary(replacing(before.primary))
                // Do not overwrite a CLI refresh between the two store writes.
                guard try normalized(readFile()) == before.file else { throw SafetyError("凭据文件已被其他操作修改。") }
                fileAttempted = true; try writeCredentialFile(replacing(before.file))
            } catch {
                func restore(_ original: Data?, read: () throws -> Data?, write: (Data?) throws -> Void) throws {
                    let current = try normalized(read()), field = try oauth(current), old = try oauth(original)
                    if field == old { return }
                    guard field == desired else { throw SafetyError("CLI 登录已被外部修改。") }
                    let restored = try CLIJSON.replacing(current, key: "claudeAiOauth", with: old)
                    try write(restored ?? (original == nil ? nil : Data("{}".utf8)))
                    guard try oauth(read()) == old else { throw SafetyError("CLI 登录还原回读未通过。") }
                }
                var restored = true
                if fileAttempted { do { try restore(before.file, read: readFile, write: writeCredentialFile) } catch { restored = false } }
                if primaryAttempted { do { try restore(before.primary, read: readPrimary, write: writeCredentialPrimary) } catch { restored = false } }
                throw SafetyError(restored ? "CLI 双存储写入未完成，已还原本次写入；同步未完成。" : "CLI 双存储还原未能确认；保留外部新登录，请停止切换。")
            }
        }
    }
}
