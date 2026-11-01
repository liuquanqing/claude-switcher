import Foundation
import CoreFoundation

public enum CLINativeRenewalOutcome: Equatable, Sendable {
    case completed, loginRequired, authorizationRequired, temporaryFailure, timedOut, unsupported
}

public enum CLICurrentRecoveryOutcome: Equatable, Sendable {
    case notNeeded, renewed, verificationPending, backupPending, needsLogin, authorizationRequired, retryLater, contextChanged, unsupported
}

public struct CLIInteractionRequired: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "登录存储需要系统授权，请手动刷新后重试。" }
}

/// Only the official CLI may change the live credential. This coordinator never
/// copies a parked login into the default directory or writes live OAuth fields.
@MainActor public enum CLICurrentRecovery {
    public static func isDue(_ login: CLIOwnedLogin, now: Date, lead: TimeInterval = 300) throws -> Bool {
        guard let oauth = login.oauth else { return true }
        let object = try CLIJSON.object(oauth)
        guard login.hasSecrets else { return true }
        if (object["accessToken"] as? String)?.isEmpty != false { return true }
        guard let expiry = object["expiresAt"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue.isFinite, expiry.doubleValue > 0 else {
            throw SafetyError("CLI 到期时间无法确认，未执行续期。")
        }
        return expiry.doubleValue <= now.addingTimeInterval(lead).timeIntervalSince1970 * 1000
    }

    public static func run(target: CLIProfileIdentity, io: CLICredentialIO,
                           now: () -> Date = Date.init,
                           finishPendingBackup: Bool = false,
                           requestNativeCheck: Bool = false,
                           contextIsCurrent: () throws -> Bool,
                           gate: () async -> Bool,
                           native: () async throws -> CLINativeRenewalOutcome,
                           verify: (String) async throws -> CLIIdentity) async throws -> CLICurrentRecoveryOutcome {
        func live() throws -> CLIOwnedLogin {
            try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
        }
        guard let expected = target.identity, expected.isComplete, try contextIsCurrent() else { return .contextChanged }
        let original = try live()
        guard try original.identity?.samePrincipal(as: expected) == true else { return .contextChanged }
        let due = try isDue(original, now: now())
        guard finishPendingBackup || requestNativeCheck || due else { return .notNeeded }
        let backupOnly = finishPendingBackup && original.usableAccessToken(now: now()) != nil
        if !backupOnly && !original.hasRefreshToken {
            if original.usableAccessToken(now: now()) == nil { return .needsLogin }
            if !requestNativeCheck { return .notNeeded }
        }
        guard await gate() else { return .retryLater }
        guard try contextIsCurrent() else { return .contextChanged }
        let before = try live()
        guard try before.identity?.samePrincipal(as: expected) == true else { return .contextChanged }
        if before != original {
            // A running CLI may already have renewed. Preserve its newer record.
            guard before.usableAccessToken(now: now()) != nil else { return .retryLater }
        }
        let result: CLINativeRenewalOutcome
        if before != original || backupOnly { result = .completed }
        else {
            do { result = try await native() }
            catch { result = .temporaryFailure }
        }
        guard try contextIsCurrent() else { return .contextChanged }
        let recovered = try live()
        if !recovered.hasSecrets && result == .loginRequired { return .needsLogin }
        guard try recovered.identity?.samePrincipal(as: expected) == true else { return .contextChanged }
        // A timeout/error can happen after the native CLI saved a rotated token.
        // Read it back before interpreting command output, and never roll it back.
        guard let access = recovered.usableAccessToken(now: now()) else {
            switch result {
            case .loginRequired: return .needsLogin
            case .authorizationRequired: return .authorizationRequired
            case .unsupported: return .unsupported
            default: return .retryLater
            }
        }
        if recovered == original && !backupOnly {
            switch result {
            case .completed: return .notNeeded
            case .loginRequired: return .needsLogin
            case .authorizationRequired: return .authorizationRequired
            case .unsupported: return .unsupported
            default: return .retryLater
            }
        }
        guard await gate(), try contextIsCurrent() else { return .verificationPending }
        guard try live() == recovered else { return .contextChanged }
        let actual: CLIIdentity
        do { actual = try await verify(access) }
        catch { return .verificationPending }
        guard actual.isComplete, actual.samePrincipal(as: expected), try contextIsCurrent(), try live() == recovered else {
            return .contextChanged
        }
        do {
            let old = try io.readBackup(target.name)
            if let old {
                let backup = try CLIBackup(data: old)
                guard try backup.login.identity?.samePrincipal(as: expected) == true else { return .backupPending }
            }
            let data = try CLIBackup.verifiedData(login: recovered, identity: actual, now: now())
            guard try contextIsCurrent(), try live() == recovered, try io.readBackup(target.name) == old else { return .contextChanged }
            try io.writeBackup(target.name, data: data)
            guard try io.readBackup(target.name) == data else { return .backupPending }
        } catch { return .backupPending }
        return .renewed
    }
}
