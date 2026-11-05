import Foundation
import SwitcherCore

@MainActor extension Store {
    var needsActiveAccountBootstrap: Bool {
        protection.desktopScope == .subscription && active?.snapshot?.identity.isComplete != true
    }
    /// Identity comes from the desktop's own verified credential. A CLI email or
    /// account UUID alone is never promoted into a desktop identity.
    func applyVerifiedDesktopIdentity(name: String, identity: CLIIdentity, tokenDigest: String? = nil, plan: String? = nil) throws {
        guard identity.isComplete, let index = profiles.firstIndex(where: { $0.name == name }) else {
            throw err("桌面档案或身份尚未确认，未改写账号资料。")
        }
        let previous = profiles[index].snapshot
        // Do not relabel another principal's historical quota as this account.
        var snapshot = previous?.identity.samePrincipal(as: identity) == true
            ? previous! : Snapshot(fetchedAt: .distantPast)
        snapshot.accountID = identity.accountID
        snapshot.organizationID = identity.organizationID
        snapshot.email = identity.email
        if let plan { snapshot.plan = plan }
        if let tokenDigest { snapshot.identityTokenDigest = tokenDigest }
        profiles[index].snapshot = snapshot
        profiles[index].signedIn = true
        cliConnection.contextDidChange()
        if !isDemo { saveCache(name, snapshot) }
    }

    /// First-install refresh must establish the active desktop identity before
    /// matching the official CLI quota to a saved card. Inactive profiles are
    /// neither inspected nor inferred from the current CLI login.
    func refreshAccountAndUsage(allowInteraction: Bool,
        observeDesktop: ((String, Bool) async throws -> CLIProfileIdentity)? = nil,
        readUsage: (() async throws -> OfficialCLIUsageCache?)? = nil) async throws {
        guard !isDemo || (observeDesktop != nil && readUsage != nil) else {
            throw err("演示模式不读取真实登录。")
        }
        let originalCurrent = current
        let scope = protection.desktopScope
        if scope == .subscription {
            let descriptor = try await (observeDesktop ?? { name, interaction in
                try await self.profileDescriptor(name, allowInteraction: interaction)
            })(originalCurrent, allowInteraction)
            guard current == originalCurrent, descriptor.name == originalCurrent,
                  let identity = descriptor.identity, identity.isComplete else {
                throw err("桌面账号身份尚未确认，未将 CLI 账号作为桌面账号。")
            }
            // The production observer normally persisted this already. This
            // commit step also keeps the injected observation path testable.
            if profiles.first(where: { $0.name == originalCurrent })?.snapshot?.identity.samePrincipal(as: identity) != true {
                try applyVerifiedDesktopIdentity(name: originalCurrent, identity: identity)
            }
        }
        let sample = try await (readUsage ?? { try await self.readSelectedCLIUsageCache() })()
        guard current == originalCurrent, protection.desktopScope == scope else {
            throw err("读取期间桌面账号发生变化，未采纳旧身份。")
        }
        applyOfficialUsage(sample)
    }
}

/// Empty parked folders are first-run slots, not detected accounts. An unreadable
/// file remains unknown rather than being presented as logged out.
func profileHasLocalData(directory: URL, cached: Snapshot?) -> Bool {
    if cached != nil { return true }
    do {
        _ = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("config.json").path)
        return true
    } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile || failure.code == .fileNoSuchFile {
        return false
    } catch { return true }
}
