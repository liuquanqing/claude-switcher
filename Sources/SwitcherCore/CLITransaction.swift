import Foundation

@MainActor public protocol CLICredentialIO: AnyObject {
    func readCredentials() throws -> Data?
    func writeCredentials(_ data: Data?) throws
    func readIdentityDocument() throws -> Data?
    func writeIdentityDocument(_ data: Data?) throws
    func readBackup(_ profile: String) throws -> Data?
    func writeBackup(_ profile: String, data: Data) throws
    func readMarker() throws -> String?
    func writeMarker(_ value: String?) throws
}

public enum CLIRestoration: Equatable, Sendable { case needsLogin, storedLogin, verifiedLogin }

/// Only preparation failures are eligible for an explicit desktop-only choice.
/// Active CLI credentials and Desktop directories have not been changed at this point.
public struct CLIPreparationFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct PreparedCLISwitch {
    let original: CLIOwnedLogin
    let originalMarker: String?
    let targetName: String
    let targetBackupBefore: Data?
    let targetBackupAfter: Data?
    let sourceName: String?
    let sourceBackup: Data?
    let targetUpgrade: Data?
    let desired: CLIOwnedLogin
    public let restoration: CLIRestoration
}

@MainActor public final class CLITransaction {
    private let io: CLICredentialIO
    private let now: () -> Date
    public init(io: CLICredentialIO, now: @escaping () -> Date = Date.init) { self.io = io; self.now = now }
    public func readOwned() throws -> CLIOwnedLogin {
        try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
    }
    private func normalized(_ data: Data?) throws -> Data? { try data.map { try CLIJSON.encode(CLIJSON.object($0)) } }

    /// Network access is supplied by the caller, after its region gate. No auth CLI is spawned.
    private func verify(_ login: CLIOwnedLogin, trusted: CLIBackup?, context: String,
                        expected: CLIIdentity?, remote: (String) async throws -> CLIIdentity) async throws -> (CLIIdentity, Bool) {
        guard login.hasSecrets, let metadata = try login.identity, metadata.isComplete else {
            throw SafetyError("\(context) CLI 登录为空或身份不完整，未修改登录；请先在原 CLI 中确认登录。")
        }
        if let expected, !metadata.samePrincipal(as: expected) {
            throw SafetyError("目标 CLI 备份与桌面账号或组织不一致，未修改账号。")
        }
        if let token = login.usableAccessToken(now: now()) {
            let identity: CLIIdentity
            do { identity = try await remote(token) }
            catch { throw SafetyError("\(context) CLI 身份核验未完成，未移动账号目录；请确认登录和网络后重试。") }
            guard identity.isComplete, identity.samePrincipal(as: metadata),
                  expected.map({ identity.samePrincipal(as: $0) }) ?? true else {
                throw SafetyError("CLI 凭据与身份块或目标组织不一致，未修改账号。")
            }
            return (identity, true)
        }
        // Existing, atomically saved proof permits an expired access token with a refresh
        // credential to be restored as pending, without inventing a background refresh flow.
        if login.hasRefreshToken, let trusted, trusted.login == login, let identity = try trusted.trustedIdentity(),
           expected.map({ identity.samePrincipal(as: $0) }) ?? true {
            return (identity, false)
        }
        throw SafetyError("\(context) CLI 登录需要刷新或重新确认；旧备份保留，目录未移动。可先用原切换器切到对应档案，在 CLI 登录后再回来重试。")
    }

    public func prepare(target: CLIProfileIdentity, profiles: [CLIProfileIdentity], requiresTargetLogin: Bool = false,
                        remote: (String) async throws -> CLIIdentity) async throws -> PreparedCLISwitch {
        let original = try readOwned()
        let originalMarker = try io.readMarker()
        let targetRaw = try normalized(io.readBackup(target.name))
        var sourceName: String?, sourceData: Data?
        var sourceIdentity: CLIIdentity?, sourceRemote = false
        if original.hasSecrets {
            guard let metadata = try original.identity, metadata.isComplete else {
                throw SafetyError("当前 CLI 身份不完整，未修改账号。")
            }
            let candidates = profiles.filter { $0.identity?.samePrincipal(as: metadata) == true }
            guard candidates.count == 1, let source = candidates.first else {
                throw SafetyError("当前 CLI 登录不能唯一关联到桌面档案，未修改账号；请先刷新档案身份。")
            }
            let prior = try io.readBackup(source.name).map(CLIBackup.init(data:))
            let checked = try await verify(original, trusted: prior, context: "当前", expected: source.identity, remote: remote)
            if let prior, prior.login.hasSecrets {
                guard let priorIdentity = try prior.login.identity, priorIdentity.samePrincipal(as: checked.0) else {
                    throw SafetyError("该档案已有其他账号或组织的 CLI 备份，未覆盖；请先在原工具确认档案和 CLI 的账号关联，再回来重试。")
                }
            }
            sourceName = source.name; sourceIdentity = checked.0; sourceRemote = checked.1
            let checkedAt = checked.1 ? now() : (prior?.verification?.checkedAt ?? now())
            sourceData = try CLIBackup.verifiedData(login: original, identity: checked.0, now: checkedAt)
        }
        let desired: CLIOwnedLogin, restoration: CLIRestoration
        var targetUpgrade: Data?
        if sourceName == target.name, sourceIdentity != nil {
            desired = original; restoration = sourceRemote ? .verifiedLogin : .storedLogin
        } else if let targetRaw {
            let backup = try CLIBackup(data: targetRaw)
            guard let expected = target.identity, expected.isComplete else {
                throw SafetyError("目标桌面身份未确认，未恢复 CLI 登录；请先刷新目标档案。")
            }
            let checked = try await verify(backup.login, trusted: backup, context: "目标", expected: expected, remote: remote)
            desired = backup.login; restoration = checked.1 ? .verifiedLogin : .storedLogin
            let checkedAt = checked.1 ? now() : (backup.verification?.checkedAt ?? now())
            targetUpgrade = try CLIBackup.verifiedData(login: desired, identity: checked.0, now: checkedAt)
        } else {
            guard !requiresTargetLogin else {
                throw SafetyError("桌面目标还没有保存的 CLI 登录；本次未同步、未清空原登录。请先在官方 CLI 登录该账号，再检查关联。")
            }
            desired = CLIOwnedLogin(oauth: nil, metadata: nil); restoration = .needsLogin
        }
        guard try readOwned() == original, try normalized(io.readBackup(target.name)) == targetRaw,
              try io.readMarker() == originalMarker else {
            throw SafetyError("CLI 登录或备份在核验期间变化，未修改账号，请重试。")
        }
        return PreparedCLISwitch(original: original, originalMarker: originalMarker, targetName: target.name, targetBackupBefore: targetRaw,
                                 targetBackupAfter: sourceName == target.name ? sourceData : (targetUpgrade ?? targetRaw),
                                 sourceName: sourceName, sourceBackup: sourceData, targetUpgrade: targetUpgrade,
                                 desired: desired, restoration: restoration)
    }

    /// A failed outgoing backup is discovered before quitting or moving Desktop.
    public func persistOutgoing(_ plan: PreparedCLISwitch) throws {
        guard try readOwned() == plan.original,
              try normalized(io.readBackup(plan.targetName)) == plan.targetBackupBefore,
              try io.readMarker() == plan.originalMarker else {
            throw SafetyError("CLI 登录在准备期间变化，未修改账号。")
        }
        if let name = plan.sourceName, let data = plan.sourceBackup {
            try io.writeBackup(name, data: data)
            guard try normalized(io.readBackup(name)) == data else { throw SafetyError("CLI 备份回读未通过，未移动桌面目录。") }
        }
        if let data = plan.targetUpgrade {
            try io.writeBackup(plan.targetName, data: data)
            guard try normalized(io.readBackup(plan.targetName)) == data else { throw SafetyError("目标 CLI 备份回读未通过，桌面目录未移动。") }
        }
    }
    public func revalidate(_ plan: PreparedCLISwitch) throws {
        guard try readOwned() == plan.original,
              try normalized(io.readBackup(plan.targetName)) == plan.targetBackupAfter,
              try io.readMarker() == plan.originalMarker else {
            throw SafetyError("CLI 登录或目标备份已变化，未覆盖新登录，请重试。")
        }
    }
    public func apply(_ plan: PreparedCLISwitch) throws -> CLIRestoration {
        try revalidate(plan)
        let oldMarker = plan.originalMarker
        var credentialsAttempted = false, identityAttempted = false, markerAttempted = false
        var credentialsWerePresent = false, identityWasPresent = false
        do {
            let credentials = try io.readCredentials()
            credentialsWerePresent = credentials != nil
            guard try CLIJSON.field(credentials, key: "claudeAiOauth") == plan.original.oauth else {
                throw SafetyError("CLI 登录在写入前变化。")
            }
            let newCredentials = try CLIJSON.replacing(credentials, key: "claudeAiOauth", with: plan.desired.oauth)
            if try normalized(credentials) != newCredentials {
                credentialsAttempted = true; try io.writeCredentials(newCredentials)
            }
            let document = try io.readIdentityDocument()
            identityWasPresent = document != nil
            guard try CLIJSON.field(document, key: "oauthAccount") == plan.original.metadata else {
                throw SafetyError("CLI 身份在写入前变化。")
            }
            let newDocument = try CLIJSON.replacing(document, key: "oauthAccount", with: plan.desired.metadata)
            if try normalized(document) != newDocument {
                identityAttempted = true; try io.writeIdentityDocument(newDocument)
            }
            markerAttempted = true; try io.writeMarker(plan.targetName)
            guard try readOwned() == plan.desired, try io.readMarker() == plan.targetName else {
                throw SafetyError("CLI 保存登录回读不一致。")
            }
            return plan.restoration
        } catch {
            if markerAttempted {
                do {
                    let marker = try io.readMarker()
                    guard marker == oldMarker || marker == plan.targetName else { throw SafetyError("changed") }
                } catch {
                    throw SafetyError("CLI 关联已被外部修改或不可读，保留当前状态；自动还原未确认，请停止切换。")
                }
            }
            if let current = try? readOwned(),
               (current.oauth != plan.original.oauth && current.oauth != plan.desired.oauth
                || current.metadata != plan.original.metadata && current.metadata != plan.desired.metadata) {
                throw SafetyError("CLI 已被外部修改，保留当前登录；自动还原未确认，请停止切换。")
            }
            var restored = true
            if credentialsAttempted {
                do {
                    let current = try io.readCredentials(), field = try CLIJSON.field(current, key: "claudeAiOauth")
                    if field != plan.original.oauth {
                        guard field == plan.desired.oauth else { throw SafetyError("CLI 已被外部修改。") }
                        let restoredValue = try CLIJSON.replacing(current, key: "claudeAiOauth", with: plan.original.oauth)
                        try io.writeCredentials(restoredValue ?? (credentialsWerePresent ? Data("{}".utf8) : nil))
                    }
                } catch { restored = false }
            }
            if identityAttempted {
                do {
                    let current = try io.readIdentityDocument(), field = try CLIJSON.field(current, key: "oauthAccount")
                    if field != plan.original.metadata {
                        guard field == plan.desired.metadata else { throw SafetyError("CLI 身份已被外部修改。") }
                        let restoredValue = try CLIJSON.replacing(current, key: "oauthAccount", with: plan.original.metadata)
                        try io.writeIdentityDocument(restoredValue ?? (identityWasPresent ? Data("{}".utf8) : nil))
                    }
                } catch { restored = false }
            }
            if markerAttempted {
                do {
                    let current = try io.readMarker()
                    if current != oldMarker {
                        guard current == plan.targetName else { throw SafetyError("CLI 关联已被外部修改。") }
                        try io.writeMarker(oldMarker)
                    }
                } catch { restored = false }
            }
            if restored {
                guard (try? readOwned()) == plan.original, (try? io.readMarker()) == oldMarker else {
                    throw SafetyError("CLI 还原未能确认，请保留数据并停止切换。")
                }
                throw SafetyError("CLI 保存或回读失败，已还原原保存登录。")
            }
            throw SafetyError("CLI 保存及还原未能全部确认；未覆盖外部新登录，请保留数据并停止切换。")
        }
    }
}

@MainActor public enum CLILinkedSwitch {
    public static func run(transaction: CLITransaction, target: CLIProfileIdentity, profiles: [CLIProfileIdentity],
                           remote: (String) async throws -> CLIIdentity, quit: () async throws -> Bool,
                           move: () throws -> (() throws -> Void)) async throws -> CLIRestoration {
        let plan: PreparedCLISwitch
        do {
            plan = try await transaction.prepare(target: target, profiles: profiles, remote: remote)
        } catch { throw CLIPreparationFailure(error.localizedDescription) }
        // A partial backup write/readback failure needs inspection, not a continue option.
        try transaction.persistOutgoing(plan)
        guard try await quit() else { throw SafetyError("Claude 未退出，账号目录未移动。") }
        try transaction.revalidate(plan)
        let undo = try move()
        do { return try transaction.apply(plan) }
        catch {
            let cause = error.localizedDescription
            do { try undo() }
            catch { throw SafetyError("CLI 切换失败，桌面目录还原也未完成；请保留数据并停止操作。") }
            throw SafetyError("\(cause) 桌面目录已还原，Claude 未重新打开。")
        }
    }
}
