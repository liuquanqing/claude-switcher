import Foundation
import CoreFoundation

/// The CLI's local status report is a record, not an authenticated API verification.
public struct CLIReportedStatus: Sendable, Equatable {
    public let loggedIn: Bool
    public let authMethod: String
    public let configDirectory: URL
    public let identity: CLIIdentity
    private static func canonical(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    public init(data: Data) throws {
        let object = try CLIJSON.object(data)
        guard let flag = object["loggedIn"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let method = object["authMethod"] as? String,
              ["none", "claude.ai", "oauth_token", "api_key", "api_key_helper", "third_party"].contains(method),
              let directory = object["configDirectory"] as? String, directory.hasPrefix("/") else {
            throw SafetyError("CLI 状态输出格式无法确认，未修改登录。")
        }
        func unique(_ keys: [String], id: Bool = false) throws -> String? {
            var values: [String] = []
            for key in keys {
                guard let raw = object[key], !(raw is NSNull) else { continue }
                guard let text = raw as? String else { throw SafetyError("CLI 身份字段无法确认。") }
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { values.append(id ? (UUID(uuidString: value)?.uuidString.lowercased() ?? value) : value) }
            }
            guard Set(values).count <= 1 else { throw SafetyError("CLI 身份字段有冲突，未作账号配对。") }
            return values.first
        }
        loggedIn = flag.boolValue; authMethod = method
        configDirectory = URL(fileURLWithPath: directory).standardizedFileURL
        identity = try CLIIdentity(accountID: unique(["accountId", "accountID", "accountUuid", "account_uuid", "userId"], id: true),
            organizationID: unique(["orgId", "organizationId", "organizationID", "organizationUuid", "organization_uuid"], id: true),
            email: unique(["email"]))
    }
    public func usesConfigurationDirectory(_ expected: URL) -> Bool {
        configDirectory.resolvingSymlinksInPath().path == expected.standardizedFileURL.resolvingSymlinksInPath().path
    }
    /// Fill a missing account UUID only when the CLI report agrees with the saved
    /// record's email AND organization. This still does not verify an access token.
    public func savedRecord(matching metadata: CLIIdentity?) -> CLIIdentity? {
        guard loggedIn, authMethod == "claude.ai" else { return nil }
        guard let metadata, metadata.isComplete, let reportedEmail = identity.email,
              let savedEmail = metadata.email,
              reportedEmail.caseInsensitiveCompare(savedEmail) == .orderedSame,
              let reportedOrg = identity.organizationID, let savedOrg = metadata.organizationID,
              Self.canonical(reportedOrg) == Self.canonical(savedOrg) else { return identity }
        if let reportedAccount = identity.accountID,
           Self.canonical(reportedAccount) != Self.canonical(metadata.accountID) { return identity }
        return CLIIdentity(accountID: identity.accountID ?? metadata.accountID,
                           organizationID: identity.organizationID, email: identity.email)
    }
    public static func sameAccountRecord(_ a: CLIIdentity?, _ b: CLIIdentity?) -> Bool? {
        guard let left = canonical(a?.accountID), let right = canonical(b?.accountID) else { return nil }
        return left == right
    }
}
