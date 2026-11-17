import Foundation

@MainActor public enum CLICurrentBackup {
    public enum Outcome: Equatable { case saved, upToDate }

    public static func save(target: CLIProfileIdentity, io: CLICredentialIO,
                            now: () -> Date = Date.init,
                            contextIsCurrent: () throws -> Bool,
                            gate: () async -> Bool = { true },
                            verify: ((String) async throws -> CLIIdentity)? = nil) async throws -> Outcome {
        func live() throws -> CLIOwnedLogin {
            try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
        }
        guard ProfileTransaction.validName(target.name), let expected = target.identity, expected.isComplete,
              try contextIsCurrent() else { throw SafetyError("账号已变化，未更新 CLI 备份。") }
        let original = try live()
        guard original.hasSecrets, try original.identity?.samePrincipal(as: expected) == true else {
            throw SafetyError("当前 CLI 登录与桌面账号不符，未更新备份。")
        }
        let previous = try io.readBackup(target.name)
        if let previous {
            let backup = try CLIBackup(data: previous)
            guard try backup.login.identity?.samePrincipal(as: expected) == true else {
                throw SafetyError("现有 CLI 备份属于其他账号或组织，未覆盖。")
            }
            if backup.login == original {
                guard try contextIsCurrent(), try live() == original,
                      try io.readBackup(target.name) == previous else {
                    throw SafetyError("登录或备份已变化，请重新检查。")
                }
                return .upToDate
            }
        }
        guard await gate(), try contextIsCurrent(), try live() == original else {
            throw SafetyError("网络或当前登录未能确认，备份尚未更新。")
        }
        let data: Data
        if let verify {
            guard let access = original.usableAccessToken(now: now()) else {
                throw SafetyError("当前 CLI 登录需由官方 CLI 续期，备份尚未更新。")
            }
            let actual = try await verify(access)
            guard actual.isComplete, actual.samePrincipal(as: expected) else {
                throw SafetyError("CLI 远端身份与当前账号不符，未更新备份。")
            }
            data = try CLIBackup.verifiedData(login: original, identity: actual, now: now())
        } else {
            guard let oauth = original.oauth, let metadata = original.metadata else {
                throw SafetyError("当前 CLI 登录不完整，未更新备份。")
            }
            data = try CLIJSON.encode(["claudeAiOauth": CLIJSON.object(oauth), "oauthAccount": CLIJSON.object(metadata)])
        }
        guard try contextIsCurrent(), try live() == original, try io.readBackup(target.name) == previous else {
            throw SafetyError("登录、账号或备份已变化，未覆盖备份。")
        }
        try io.writeBackup(target.name, data: data)
        guard try io.readBackup(target.name) == data else {
            throw SafetyError("CLI 备份回读未通过，当前登录保持原样。")
        }
        guard try contextIsCurrent(), try live() == original else {
            throw SafetyError("CLI 已产生新登录，刚保存的备份需要再次更新。")
        }
        return .saved
    }
}
