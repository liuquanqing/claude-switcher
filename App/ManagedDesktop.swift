import AppKit
import SwitcherCore

@MainActor func managedDesktopApplication(_ files: SafetyFiles) -> NSRunningApplication? {
    guard let session = files.loadManagedDesktop() else { return nil }
    guard session.authorizes(DesktopModeInspector.evidence(support: files.directory.deletingLastPathComponent())) else { return nil }
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        session.matches(pid: $0.processIdentifier, launchedAt: $0.launchDate)
    }
}

@MainActor func currentSubscriptionDesktopRecord() throws -> ManagedDesktopSession {
    let evidence = DesktopModeInspector.evidence(support: support)
    guard evidence.scope == .subscription, let revision = evidence.revision else {
        throw err("订阅配置未确认；没有改变现有桌面的保护范围。")
    }
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard applications.count == 1, let application = applications.first, let date = application.launchDate else {
        throw err("当前桌面实例不唯一或身份无法确认；请保留一个订阅桌面后重试。")
    }
    return ManagedDesktopSession(pid: application.processIdentifier, launchedAt: date, modeRevision: revision)
}

@MainActor func launchProtectedDesktop(files: SafetyFiles) async throws {
    let current = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if !current.isEmpty {
        guard let owned = managedDesktopApplication(files) else {
            throw err("当前桌面未保护，未切到前台。可在保护卡片点“纳入保护”，无需退出重开；确认前不接管、不关闭。")
        }
        owned.activate(options: []); return
    }
    guard DesktopModeInspector.read(support: support) == .subscription else { throw err("订阅桌面配置未确认，未启动客户端。") }
    let application = try await launchClaude()
    let evidence = DesktopModeInspector.evidence(support: support)
    guard let date = application.launchDate, evidence.scope == .subscription, let revision = evidence.revision else {
        application.terminate()
        throw err("启动时模式变化，未纳入保护；已请求退出本次新启动，请确认客户端状态。")
    }
    do {
        try files.save(ManagedDesktopSession(pid: application.processIdentifier, launchedAt: date, modeRevision: revision), to: files.managedDesktopURL)
    } catch {
        application.terminate()
        throw err("本次新启动的桌面未能记录保护归属，已请求退出；原有档案保留。")
    }
}
