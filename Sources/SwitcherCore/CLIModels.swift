import Foundation
import CryptoKit

public enum CLILoginStatus: String, Codable, Sendable {
    case unverified, matched, different, needsLogin, otherAuthentication, unsupportedStorage
}

public enum DesktopProtectionScope: String, Codable, Sendable {
    case subscription, api, unknown
}

public enum ProtectedTarget: Sendable { case desktop, cli }

public struct ManagedDesktopSession: Codable, Equatable, Sendable {
    public let pid: Int32
    public let launchedAt: Date
    public let modeRevision: String?
    public init(pid: Int32, launchedAt: Date, modeRevision: String? = nil) {
        self.pid = pid; self.launchedAt = launchedAt; self.modeRevision = modeRevision
    }
    public func matches(pid: Int32, launchedAt: Date?) -> Bool {
        guard let launchedAt else { return false }
        return self.pid == pid && abs(self.launchedAt.timeIntervalSince(launchedAt)) < 0.001
    }
    public func authorizes(_ evidence: DesktopModeEvidence) -> Bool {
        evidence.scope == .subscription && modeRevision != nil && modeRevision == evidence.revision
    }
}

public struct CLIIdentity: Codable, Equatable, Sendable {
    public var accountID: String?
    public var organizationID: String?
    public var email: String?
    public init(accountID: String?, organizationID: String?, email: String?) {
        self.accountID = accountID; self.organizationID = organizationID; self.email = email
    }
    private static func normalizedID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }
    public var isComplete: Bool { Self.normalizedID(accountID) != nil && Self.normalizedID(organizationID) != nil }
    public func samePrincipal(as other: CLIIdentity) -> Bool {
        isComplete && other.isComplete && Self.normalizedID(accountID) == Self.normalizedID(other.accountID)
            && Self.normalizedID(organizationID) == Self.normalizedID(other.organizationID)
    }
    public static func profile(_ json: [String: Any]) -> CLIIdentity {
        let account = json["account"] as? [String: Any] ?? [:]
        let org = json["organization"] as? [String: Any] ?? [:]
        func unique(_ values: [Any?], identity: Bool = false) -> String? {
            let strings = values.compactMap { value -> String? in
                guard let s = value as? String else { return nil }
                if identity { return Self.normalizedID(s) }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return Set(strings).count == 1 ? strings.first : nil
        }
        return CLIIdentity(accountID: unique([account["uuid"], json["accountUuid"], json["account_uuid"]], identity: true),
                           organizationID: unique([org["uuid"], json["organizationUuid"], json["organization_uuid"]], identity: true),
                           email: unique([account["email"], account["emailAddress"], account["email_address"],
                                          json["email"], json["emailAddress"], json["email_address"]]))
    }
    public static func metadata(_ data: Data?) throws -> CLIIdentity? {
        guard let data else { return nil }
        let json = try CLIJSON.object(data)
        return CLIIdentity(accountID: json["accountUuid"] as? String,
                           organizationID: json["organizationUuid"] as? String,
                           email: json["emailAddress"] as? String)
    }
}

public struct CLIProfileIdentity: Equatable, Sendable {
    public let name: String
    public let identity: CLIIdentity?
    public init(name: String, identity: CLIIdentity?) { self.name = name; self.identity = identity }
}

public enum CLIJSON {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SafetyError("登录材料格式不兼容，未修改登录。")
        }
        return value
    }
    public static func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    public static func field(_ document: Data?, key: String) throws -> Data? {
        guard let document, let value = try object(document)[key], !(value is NSNull) else { return nil }
        guard let value = value as? [String: Any] else { throw SafetyError("登录字段格式不兼容，未修改登录。") }
        return try encode(value)
    }
    /// Only replace the owned field. Current unrelated settings/credentials stay in place.
    public static func replacing(_ document: Data?, key: String, with value: Data?) throws -> Data? {
        var json = try document.map(object) ?? [:]
        json[key] = try value.map(object)
        return json.isEmpty ? nil : try encode(json)
    }
}

public struct CLIOwnedLogin: Equatable, Sendable {
    public let oauth: Data?
    public let metadata: Data?
    public init(credentials: Data?, identityDocument: Data?) throws {
        oauth = try CLIJSON.field(credentials, key: "claudeAiOauth")
        metadata = try CLIJSON.field(identityDocument, key: "oauthAccount")
    }
    public init(oauth: Data?, metadata: Data?) { self.oauth = oauth; self.metadata = metadata }
    public var identity: CLIIdentity? { get throws { try CLIIdentity.metadata(metadata) } }
    public var hasSecrets: Bool {
        guard let oauth, let json = try? CLIJSON.object(oauth) else { return false }
        return !(json["accessToken"] as? String ?? "").isEmpty || !(json["refreshToken"] as? String ?? "").isEmpty
    }
    public var hasRefreshToken: Bool {
        guard let oauth, let json = try? CLIJSON.object(oauth) else { return false }
        return !(json["refreshToken"] as? String ?? "").isEmpty
    }
    public func usableAccessToken(now: Date) -> String? {
        guard let oauth, let json = try? CLIJSON.object(oauth),
              let token = json["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expires = json["expiresAt"] as? NSNumber,
           expires.doubleValue <= now.timeIntervalSince1970 * 1000 { return nil }
        return token
    }
    public var digest: String {
        var data = Data("claude-switcher-owned-login-v1\n".utf8)
        data.append(oauth ?? Data("null".utf8)); data.append(0x0a)
        data.append(metadata ?? Data("null".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CLIVerification: Codable, Sendable {
    public let version: Int
    public let identity: CLIIdentity
    public let digest: String
    public let checkedAt: Date
    public init(login: CLIOwnedLogin, identity: CLIIdentity, checkedAt: Date) {
        version = 1; self.identity = identity; digest = login.digest; self.checkedAt = checkedAt
    }
}

public struct CLIBackup {
    public let login: CLIOwnedLogin
    public let verification: CLIVerification?
    public init(data: Data) throws {
        login = CLIOwnedLogin(oauth: try CLIJSON.field(data, key: "claudeAiOauth"),
                              metadata: try CLIJSON.field(data, key: "oauthAccount"))
        if let stamp = try CLIJSON.object(data)["_claudeSwitcherVerification"],
           let bytes = try? JSONSerialization.data(withJSONObject: stamp) {
            verification = try? JSONDecoder().decode(CLIVerification.self, from: bytes)
        } else { verification = nil }
    }
    public func trustedIdentity() throws -> CLIIdentity? {
        guard let verification, verification.version == 1,
              verification.digest == login.digest,
              let metadata = try login.identity, metadata.samePrincipal(as: verification.identity) else { return nil }
        return verification.identity
    }
    public static func verifiedData(login: CLIOwnedLogin, identity: CLIIdentity, now: Date) throws -> Data {
        guard login.hasSecrets, let oauth = login.oauth, let identityData = login.metadata,
              let metadata = try login.identity, metadata.samePrincipal(as: identity) else {
            throw SafetyError("CLI 凭据与身份未配对，未保存备份。")
        }
        let stamp = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CLIVerification(login: login, identity: identity, checkedAt: now)))
        return try CLIJSON.encode(["claudeAiOauth": try CLIJSON.object(oauth),
                                   "oauthAccount": try CLIJSON.object(identityData),
                                   "_claudeSwitcherVerification": stamp])
    }
}
