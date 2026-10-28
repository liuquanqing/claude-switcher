import Foundation
import CryptoKit
import Darwin

public struct AuthenticationConfiguration: Equatable, Sendable {
    public let otherAuthentication: Bool
    public let unsupportedStorage: Bool
    public let malformed: Bool
    public var fileCredentialsPresent = false
    public var customDirectory = false
    public var allowsSubscriptionMutation: Bool { !otherAuthentication && !unsupportedStorage && !malformed }
    public var explanation: String? {
        if malformed { return "默认 CLI 配置无法读取或解析，未修改订阅登录。" }
        if unsupportedStorage {
            if customDirectory { return "检测到自定义 CLI 配置目录；当前适配器只支持默认目录，登录来源未核验，未修改登录。" }
            return "默认 CLI 登录存储未适配，未核验或修改登录。"
        }
        if otherAuthentication { return "默认 CLI 配置含其他认证来源，可能覆盖订阅登录；请继续用原工具处理。" }
        return nil
    }
    public static func inspect(environment: [String: String], documents: [Data],
                               fallbackPresent: Bool = false, unreadable: Bool = false) -> Self {
        let keys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                    "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE"]
        let switches = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
        func enabled(_ value: Any?) -> Bool { ["1", "true", "yes"].contains(String(describing: value ?? "").lowercased()) }
        var other = keys.contains { environment[$0]?.isEmpty == false } || switches.contains { enabled(environment[$0]) }
        var custom = environment["CLAUDE_CONFIG_DIR"]?.isEmpty == false
        var bad = unreadable
        for document in documents {
            guard let object = try? CLIJSON.object(document) else { bad = true; continue }
            if let raw = object["env"], !(raw is [String: Any]) { bad = true }
            for key in ["apiKeyHelper", "primaryApiKey", "forceLoginMethod"] {
                if let raw = object[key], !(raw is String), !(raw is NSNull) { bad = true }
            }
            let env = object["env"] as? [String: Any] ?? [:]
            other = other || keys.contains { key in
                guard let value = env[key] else { return false }
                return !(value is NSNull) && String(describing: value).isEmpty == false
            }
            other = other || switches.contains { enabled(env[$0]) }
            custom = custom || (env["CLAUDE_CONFIG_DIR"] as? String)?.isEmpty == false
            other = other || (object["apiKeyHelper"] as? String)?.isEmpty == false
                || (object["primaryApiKey"] as? String)?.isEmpty == false
                || ["console", "gateway"].contains(object["forceLoginMethod"] as? String ?? "")
        }
        return Self(otherAuthentication: other, unsupportedStorage: custom, malformed: bad,
                    fileCredentialsPresent: fallbackPresent, customDirectory: custom)
    }
    /// Returns classification only. No key, provider URL or settings contents are logged.
    public static func read(home: URL, cwd: URL, environment: [String: String],
                            managedSettings: URL? = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")) -> Self {
        var paths = [home.appendingPathComponent(".claude/settings.json")]
        if let managedSettings { paths.append(managedSettings) }
        var directory = cwd.standardizedFileURL
        while true {
            paths.append(directory.appendingPathComponent(".claude/settings.json"))
            paths.append(directory.appendingPathComponent(".claude/settings.local.json"))
            if directory == home.standardizedFileURL || directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
        var seen = Set<String>(), documents: [Data] = [], unreadable = false
        for path in paths where seen.insert(path.path).inserted {
            do { documents.append(try Data(contentsOf: path)) }
            catch let e as CocoaError where e.code == .fileReadNoSuchFile { continue }
            catch { unreadable = true }
        }
        let fallback = home.appendingPathComponent(".claude/.credentials.json")
        let present: Bool
        do { _ = try fallback.resourceValues(forKeys: [.fileSizeKey]); present = true }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { present = false }
        catch { unreadable = true; present = true }
        return inspect(environment: environment, documents: documents, fallbackPresent: present, unreadable: unreadable)
    }
}

public struct DesktopModeEvidence: Equatable, Sendable {
    public let scope: DesktopProtectionScope
    public let revision: String?
    public init(scope: DesktopProtectionScope, revision: String?) { self.scope = scope; self.revision = revision }
}

public enum DesktopModeInspector {
    /// Configuration-level classification, not a claim about an already running process.
    public static func classify(_ documents: [Data], unreadable: Bool = false) -> DesktopProtectionScope {
        guard !unreadable else { return .unknown }
        if documents.isEmpty { return .subscription }
        var modes = Set<String>()
        for data in documents {
            guard let object = try? CLIJSON.object(data) else { return .unknown }
            if let raw = object["deploymentMode"] {
                guard let mode = raw as? String, ["1p", "3p"].contains(mode) else { return .unknown }
                modes.insert(mode)
            } else { modes.insert("1p") }
        }
        guard modes.count == 1 else { return .unknown }
        return modes.first == "1p" ? .subscription : .api
    }
    public static func read(support: URL) -> DesktopProtectionScope {
        evidence(support: support).scope
    }
    /// Bind a confirmed process to this generation of the mode configuration. Returning
    /// from API to 1p does not silently re-authorize an old process record.
    public static func evidence(support: URL) -> DesktopModeEvidence {
        var documents: [Data] = [], generations = Data()
        for root in ["Claude", "Claude-3p"] {
            let path = support.appendingPathComponent(root + "/claude_desktop_config.json")
            do {
                let handle = try FileHandle(forReadingFrom: path)
                defer { try? handle.close() }
                var before = stat(), after = stat(), current = stat()
                guard fstat(handle.fileDescriptor, &before) == 0 else { return .init(scope: .unknown, revision: nil) }
                let data = try handle.readToEnd() ?? Data()
                let currentHandle = try FileHandle(forReadingFrom: path)
                defer { try? currentHandle.close() }
                guard fstat(handle.fileDescriptor, &after) == 0,
                      fstat(currentHandle.fileDescriptor, &current) == 0 else { return .init(scope: .unknown, revision: nil) }
                func generation(_ info: stat) -> String {
                    "\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
                }
                guard generation(before) == generation(after), generation(after) == generation(current) else {
                    return .init(scope: .unknown, revision: nil)
                }
                documents.append(data)
                generations.append(Data((root + ":" + generation(after) + ":").utf8))
                generations.append(contentsOf: SHA256.hash(data: data))
            }
            catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
                generations.append(Data((root + ":absent;").utf8))
            }
            catch { return .init(scope: .unknown, revision: nil) }
        }
        let scope = classify(documents)
        let revision = scope == .unknown ? nil : SHA256.hash(data: generations).map { String(format: "%02x", $0) }.joined()
        return .init(scope: scope, revision: revision)
    }
}
