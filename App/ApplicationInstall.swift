import AppKit
import SwitcherCore

@MainActor enum ApplicationInstall {
    static func hasActiveWork(_ store: Store) -> Bool {
        store.busy != nil || store.refreshing || store.statusRefreshInProgress
            || store.automaticRefreshInProgress || store.cliStatusRefreshing || store.currentCLIRecoveryRunning
            || store.protection.working || CopyWindow.isWorking(for: store) || store.cliConnection.isBusy
    }
    static var jobs: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppReleasePolicy.bundleID + "/Installations")
    }
    private static func registration(files: SafetyFiles, helper: URL) async -> (Bool, URL?) {
        let directory = files.directory
        return await Task.detached(priority: .utility) {
            let service = GuardService(files: SafetyFiles(directory: directory), helper: helper)
            return (service.registered, service.registeredHelper)
        }.value
    }
    static func request(file: URL, release: AppRelease, checksum: String, currentBuild: String, store: Store) async throws {
        guard !store.isDemo, !store.updating else { throw SafetyError("当前操作尚未完成，请稍后更新。") }
        let idleDeadline = Date().addingTimeInterval(30)
        while hasActiveWork(store) {
            guard Date() < idleDeadline else { throw SafetyError("当前操作尚未完成，请稍后更新。") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !store.protection.hasEditedSettings else { throw SafetyError("保护设置尚未保存，请先保存或还原。") }
        let target = Bundle.main.bundleURL.standardizedFileURL
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: AppReleasePolicy.bundleID)
            .filter { $0.bundleURL?.standardizedFileURL.path == target.path }
        guard instances.count == 1 else { throw SafetyError("还有其他切换器实例，请退出后再更新。") }
        let permitted = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard permitted.contains(target.deletingLastPathComponent()),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              Bundle.main.bundleIdentifier == AppReleasePolicy.bundleID else {
            throw SafetyError("应用程序目录不可写，请手动安装此更新。")
        }
        let helper = target.appendingPathComponent("Contents/Helpers/ClaudeUpdater")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SafetyError("当前版本缺少更新助手，请手动安装一次。") }
        store.updating = true
        defer { store.updating = false }
        // Repair the registered component as part of this explicit update task.
        // A healthy current registration returns without restarting the guard.
        let initialRegistration = await registration(files: store.protection.files, helper: store.protection.service.helper)
        if FileManager.default.fileExists(atPath: store.protection.files.configURL.path) || initialRegistration.0 {
            let config = try store.protection.files.loadConfig()
            if config.enabled {
                await store.protection.retryProtection()
                let repaired = await registration(files: store.protection.files, helper: store.protection.service.helper)
                guard store.protection.operationError == nil,
                      repaired.1?.standardizedFileURL == target.appendingPathComponent("Contents/Helpers/ClaudeGuard") else {
                    throw SafetyError(store.protection.operationError ?? "保护组件尚未就绪，请重试保护。")
                }
            }
        }
        let id = UUID()
        let staged = target.deletingLastPathComponent().appendingPathComponent(".claude-switcher-update-\(id.uuidString).app")
        try await UpdatePackageVerifier.verify(file, release: release, checksum: checksum, currentBuild: currentBuild, stageTo: staged)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
        guard let build = info["CFBundleVersion"] as? String else { throw SafetyError("更新构建号无法确认。") }
        let plan = AppUpdateInstallPlan(id: id, application: target, stagedApplication: staged,
                                        oldBuild: currentBuild, newBuild: build, release: release.version)
        try plan.validatePaths()
        let directory = jobs.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let planFile = directory.appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan).write(to: planFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planFile.path)
        let resultFile = directory.appendingPathComponent("result.json")
        let task = Process()
        task.executableURL = helper; task.arguments = ["--install", planFile.path]
        task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run()
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let data = try? Data(contentsOf: resultFile), let result = try? JSONDecoder().decode(AppUpdateInstallResult.self, from: data), result.id == id {
                if result.state == .waitingForExit {
                    guard !hasActiveWork(store), !store.protection.hasEditedSettings else {
                        task.terminate(); throw SafetyError("当前操作尚未完成，原版本已保留。")
                    }
                    NSApp.terminate(nil)
                    // If AppKit refuses termination, keep the UI responsive until
                    // the helper confirms it has left the old bundle in place.
                    while task.isRunning { try await Task.sleep(nanoseconds: 250_000_000) }
                    let data = try Data(contentsOf: resultFile)
                    let final = try JSONDecoder().decode(AppUpdateInstallResult.self, from: data)
                    throw SafetyError(final.message ?? "切换器尚未退出，原版本已保留。")
                }
                if [.failed, .rolledBack, .recoveryRequired].contains(result.state) {
                    throw SafetyError(result.message ?? "更新未完成，原版本已保留。")
                }
            }
            guard task.isRunning else { throw SafetyError("更新助手未完成准备，原版本已保留。") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if task.isRunning { task.terminate() }
        throw SafetyError("更新准备超时，原版本已保留。")
    }

    /// Only our own pending requests can acknowledge a successful restart.
    static func acknowledgePending(store: Store) async {
        guard !store.isDemo, let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let directories = try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for directory in directories {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("plan.json")),
                  let plan = try? JSONDecoder().decode(AppUpdateInstallPlan.self, from: data),
                  plan.id.uuidString == directory.lastPathComponent,
                  plan.application.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path else { continue }
            let resultFile = directory.appendingPathComponent("result.json")
            guard let data = try? Data(contentsOf: resultFile), let state = try? JSONDecoder().decode(AppUpdateInstallResult.self, from: data),
                  state.id == plan.id else { continue }
            if build == plan.oldBuild, let argument = CommandLine.arguments.firstIndex(of: "--complete-update"),
               argument + 1 < CommandLine.arguments.count,
               URL(fileURLWithPath: CommandLine.arguments[argument + 1]).standardizedFileURL == directory.appendingPathComponent("plan.json").standardizedFileURL {
                store.applicationUpdateNotice = appText("settings.updateKeptPrevious", language: store.appLanguage)
                store.onShowAccounts?()
                continue
            }
            guard plan.newBuild == build, [.replacing, .launching, .recoveryRequired].contains(state.state) else { continue }
            store.updating = true
            defer { store.updating = false }
            let registered = await registration(files: store.protection.files, helper: store.protection.service.helper)
            if FileManager.default.fileExists(atPath: store.protection.files.configURL.path) || registered.0 {
                do {
                    let config = try store.protection.files.loadConfig()
                    if config.enabled {
                        let since = (try? resultFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                        try await GuardStartup.wait(config: config, startedAt: since, timeout: 22,
                            receipt: { store.protection.files.loadReceipt() },
                            stillEnabled: { (try? store.protection.files.loadConfig()) == config })
                    }
                } catch { continue }
            }
            let ack = AppUpdateInstallResult(id: plan.id, state: .complete)
            try? JSONEncoder().encode(ack).write(to: directory.appendingPathComponent("acknowledged.json"), options: .atomic)
            if state.state == .recoveryRequired { try? JSONEncoder().encode(ack).write(to: resultFile, options: .atomic) }
            store.applicationUpdateNotice = appText("settings.updatedVersion", language: store.appLanguage,
                                                   arguments: ["version": plan.release])
            store.onShowAccounts?()
        }
    }
}
