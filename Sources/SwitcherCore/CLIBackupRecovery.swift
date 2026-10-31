import Foundation

/// A native renewal keeps its durable recovery copy until the verified backup has
/// been written and read back. Cleanup is never run on a failure path.
@MainActor public struct CLIRecoveredLogin {
    public let login: CLIOwnedLogin
    public let finish: () throws -> Void
    public init(login: CLIOwnedLogin, finish: @escaping () throws -> Void = {}) {
        self.login = login; self.finish = finish
    }
}

public struct CLIRecoveryPersistenceFailure: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "新 CLI 登录尚未可靠保存，恢复资料已保留；尚未切换。" }
}

@MainActor public enum CLIBackupRecovery {
    public enum Outcome: Equatable { case notNeeded, recovered, recoveredCleanupPending }

    /// Called by explicit switch/sync, after the network gate and before Desktop quits.
    /// Does not write the default CLI, its marker, or any Desktop directory.
    public static func prepare(target: CLIProfileIdentity, io: CLICredentialIO, now: () -> Date = Date.init,
                               renew: (CLIOwnedLogin, CLIIdentity) async throws -> CLIRecoveredLogin,
                               remote: (String) async throws -> CLIIdentity) async throws -> Outcome {
        let original = try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
        guard let expected = target.identity, expected.isComplete else { return .notNeeded }
        // A newer native login wins over a parked copy, even if the copy is expired.
        if try original.identity?.samePrincipal(as: expected) == true { return .notNeeded }
        guard let raw = try io.readBackup(target.name) else { return .notNeeded }
        let backup = try CLIBackup(data: raw)
        guard let identity = try backup.login.identity, identity.samePrincipal(as: expected) else {
            throw SafetyError("目标 CLI 备份与桌面账号或组织不一致，未修改账号。")
        }
        guard backup.login.usableAccessToken(now: now()) == nil else { return .notNeeded }
        guard backup.login.hasRefreshToken else {
            throw SafetyError("目标 CLI 登录已无法自动恢复，请在官方 CLI 重新登录该账号。")
        }
        // Preserve the established stored-login path. Native CLI can renew a
        // previously verified login when it is next used; do not force rotation.
        if try backup.trustedIdentity()?.samePrincipal(as: expected) == true { return .notNeeded }
        let recovered = try await renew(backup.login, expected)
        guard let actualLocal = try recovered.login.identity, actualLocal.samePrincipal(as: expected),
              let access = recovered.login.usableAccessToken(now: now()) else {
            throw SafetyError("官方 CLI 未提供可核验的目标登录，恢复资料已保留；尚未切换。")
        }
        let actual: CLIIdentity
        do { actual = try await remote(access) }
        catch { throw SafetyError("目标 CLI 在线核验未完成，恢复资料已保留；请稍后重试。") }
        guard actual.isComplete, actual.samePrincipal(as: expected) else {
            throw SafetyError("恢复的 CLI 登录与目标账号不一致，未覆盖原备份。")
        }
        // A real CLI or another switcher may have written while renewal was running.
        guard try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument()) == original,
              try io.readBackup(target.name).map({ try CLIJSON.encode(CLIJSON.object($0)) }) == CLIJSON.encode(CLIJSON.object(raw)) else {
            throw SafetyError("登录或备份在恢复期间变化，恢复资料已保留；请重新检查。")
        }
        let verified = try CLIBackup.verifiedData(login: recovered.login, identity: actual, now: now())
        do {
            try io.writeBackup(target.name, data: verified)
            guard try io.readBackup(target.name).map({ try CLIJSON.encode(CLIJSON.object($0)) }) == verified else {
                throw SafetyError("readback")
            }
        } catch {
            throw CLIRecoveryPersistenceFailure()
        }
        do { try recovered.finish(); return .recovered }
        catch { return .recoveredCleanupPending }
    }
}
