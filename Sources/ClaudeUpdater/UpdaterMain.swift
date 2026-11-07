import Foundation
import AppKit
import Security
import SwitcherCore

enum InstallTrust {
    static let bundleID = "dev.claudeswitcher.candidate"
    static func signingTeam() throws -> String {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw SafetyError("更新助手的签名身份无法确认。")
        }
        return team
    }
    static func info(_ app: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
    }
    /// Every participating bundle must have a valid Developer ID identity. A
    /// previously installed local preview may predate notarization; the newly
    /// downloaded DMG and its app are still required to pass Gatekeeper before
    /// this helper is invoked. Never exempt the incoming package from this.
    static func verify(_ app: URL, team: String, build: String, requireNotarization: Bool = false) throws {
        let d = try info(app)
        guard d["CFBundleIdentifier"] as? String == bundleID, d["CFBundleVersion"] as? String == build,
              !d.keys.contains(where: { $0.hasPrefix("CSPreview") }) else { throw SafetyError("更新应用身份或版本不符。") }
        var requirement: SecRequirement?, code: SecStaticCode?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"\(bundleID)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw SafetyError("应用签名或系统验证未通过。")
        }
        if requireNotarization {
            guard try LocalCommand.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).0 == 0 else {
                throw SafetyError("应用签名或系统验证未通过。")
            }
        }
    }
    static func verifyGuardPath(_ application: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = SafetyFiles(directory: home.appendingPathComponent("Library/Application Support/ClaudeSwitcher"))
        let service = GuardService(files: files, helper: application.appendingPathComponent("Contents/Helpers/ClaudeGuard"))
        guard FileManager.default.fileExists(atPath: files.configURL.path) || service.registered else { return }
        let config = try files.loadConfig()
        guard config.enabled else { return }
        guard service.registeredHelper?.standardizedFileURL == service.helper.standardizedFileURL else {
            throw SafetyError("保护组件路径已变化，请先重试保护。")
        }
    }
}

@main struct ClaudeUpdater {
    @MainActor static func main() async {
        do { try await execute() }
        catch { exit(1) }
    }
    @MainActor static func execute() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "--install" else { throw SafetyError("无效更新请求。") }
        let file = URL(fileURLWithPath: args[2]).standardizedFileURL
        let jobs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(InstallTrust.bundleID + "/Installations").standardizedFileURL
        guard file.lastPathComponent == "plan.json", file.deletingLastPathComponent().deletingLastPathComponent() == jobs,
              UUID(uuidString: file.deletingLastPathComponent().lastPathComponent) != nil,
              try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SafetyError("无效更新记录。") }
        let plan = try JSONDecoder().decode(AppUpdateInstallPlan.self, from: Data(contentsOf: file))
        guard plan.id.uuidString == file.deletingLastPathComponent().lastPathComponent else { throw SafetyError("更新记录不匹配。") }
        let team = try InstallTrust.signingTeam()
        let resultFile = file.deletingLastPathComponent().appendingPathComponent("result.json")
        let acknowledgement = file.deletingLastPathComponent().appendingPathComponent("acknowledged.json")
        func running() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: InstallTrust.bundleID).filter {
                $0.bundleURL?.standardizedFileURL.path == plan.application.standardizedFileURL.path
            }
        }
        let currentBuild = try InstallTrust.info(plan.application)["CFBundleVersion"] as? String
        let stagedBuild = try InstallTrust.info(plan.stagedApplication)["CFBundleVersion"] as? String
        let resuming = currentBuild == plan.newBuild && stagedBuild == plan.oldBuild
        var replacementDone = resuming
        let outcome = await AppUpdateInstall.run(plan: plan, operations: .init(validate: {
            try plan.validatePaths()
            let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            guard roots.contains(plan.application.deletingLastPathComponent().standardizedFileURL) else {
                throw SafetyError("请先将应用安装到应用程序目录。")
            }
            try InstallTrust.verify(plan.application, team: team, build: replacementDone ? plan.newBuild : plan.oldBuild)
            try InstallTrust.verify(plan.stagedApplication, team: team, build: replacementDone ? plan.oldBuild : plan.newBuild,
                                    requireNotarization: !replacementDone)
            try InstallTrust.verifyGuardPath(plan.application)
        }, isRunning: { !running().isEmpty }, exchange: {
            // Recheck both sealed bundles before either the upgrade or rollback.
            try InstallTrust.verify(plan.application, team: team, build: replacementDone ? plan.newBuild : plan.oldBuild)
            try InstallTrust.verify(plan.stagedApplication, team: team, build: replacementDone ? plan.oldBuild : plan.newBuild)
            try AppUpdateInstallPlan.exchange(plan.application, plan.stagedApplication)
            replacementDone.toggle()
        }, launch: {
            if !running().isEmpty { return }
            try InstallTrust.verify(plan.application, team: team, build: replacementDone ? plan.newBuild : plan.oldBuild)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            // A retained original or another preview with the same identifier
            // must not substitute for the exact bundle we just installed.
            config.createsNewApplicationInstance = true
            config.arguments = ["--complete-update", file.path]
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: plan.application, configuration: config) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }, acknowledged: {
            guard let data = try? Data(contentsOf: acknowledgement),
                  let value = try? JSONDecoder().decode(AppUpdateInstallResult.self, from: data) else { return false }
            return value.id == plan.id && value.state == .complete && !running().isEmpty
        }, quitNewApplication: {
            for app in running() { guard app.terminate() else { throw SafetyError("新版尚未退出，两个版本已保留。") } }
            for _ in 0..<40 {
                if running().isEmpty { return }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw SafetyError("新版尚未退出，两个版本已保留。")
        }, record: { result in
            try JSONEncoder().encode(result).write(to: resultFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resultFile.path)
        }), resumeAfterSwap: resuming)
        exit(outcome.state == .complete ? 0 : 1)
    }
}
