import Foundation
import SwiftUI
import SwitcherCore

struct ManualNetworkCheck {
    let checkedAt: Date
    let targetCountry: String?
    let observation: NetworkObservation?
    let decision: SafetyDecision
    let validationMessage: String?
    var passed: Bool { decision.allowed }
}

@MainActor
final class ProtectionController: ObservableObject {
    @Published var country = "SG"
    @Published private(set) var activeCountry: String?
    @Published private(set) var activeProxyMode: ProxyMode?
    @Published var mode: ProxyMode = .shadowrocket
    @Published var status = "保护未启用"
    @Published var enabled = false
    @Published var guardOnline = false
    @Published var working = false
    @Published private(set) var checking = false
    @Published private(set) var lastCheckSummary: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastCheckReport: ManualNetworkCheck?
    @Published var lastDecision = SafetyDecision(.disabled)
    @Published private(set) var operationError: String?
    @Published private(set) var desktopScope: DesktopProtectionScope = .unknown
    @Published private(set) var desktopScopeDetail: String?
    @Published private(set) var desktopManaged = false
    @Published private(set) var apiConfiguration: APIConfigurationStatus = .unconfirmed
    private let demo: Bool
    private var demoNetwork = NetworkObservation(proxyConnected: true, tunOnline: true, country: "SG")
    private var timer: Timer?
    private var refreshing = false
    private let worker: any GuardWorking
    let files: SafetyFiles
    let service: GuardService
    var hasUnsavedChanges: Bool {
        country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != activeCountry || mode != activeProxyMode
    }
    var exitStatusText: String {
        if !enabled { return "保护未启用" }
        return guardOnline ? "后台保护继续运行" : "保护状态待确认"
    }

    init(demo: Bool = false, testFiles: SafetyFiles? = nil, worker: (any GuardWorking)? = nil) {
        self.demo = demo
        files = testFiles ?? SafetyFiles(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeSwitcher"))
        service = GuardService(files: files, helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClaudeGuard"))
        self.worker = worker ?? GuardWorker(directory: files.directory, helper: service.helper)
        if demo {
            desktopScope = .subscription; desktopManaged = true; apiConfiguration = .subscription
            enabled = true; guardOnline = true; activeCountry = "SG"; activeProxyMode = .shadowrocket; status = "守卫在线 · 目标 SG · 退出界面后继续保护"
            lastDecision = SafetyDecision(.allowed, expected: "SG", observed: "SG")
            if CommandLine.arguments.contains("--demo-blocked") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewBlocked") as? Bool == true {
                demoNetwork.country = "JP"
                lastDecision = SafetyDecision(.countryMismatch, expected: "SG", observed: "JP")
                status = "演示：出口 JP 与目标 SG 不一致，已阻止打开。"
            }
            if Bundle.main.object(forInfoDictionaryKey: "CSPreviewProxyDisconnected") as? Bool == true {
                demoNetwork = NetworkObservation(proxyConnected: false, tunOnline: false, country: nil)
                lastDecision = SafetyDecision(.proxyDisconnected)
                status = "演示：模拟代理未连接。"
            }
            if CommandLine.arguments.contains("--demo-guard-unknown") {
                guardOnline = false; lastDecision = SafetyDecision(.staleReceipt)
                status = "演示：守卫回执过期，保护状态待确认。"
            }
            if CommandLine.arguments.contains("--demo-api") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewAPI") as? Bool == true {
                desktopScope = .api; desktopManaged = false
                switch Bundle.main.object(forInfoDictionaryKey: "CSPreviewAPIManager") as? String {
                case "ccswitch": apiConfiguration = .ccSwitch
                case "unknown": apiConfiguration = .unknownAPI
                default: apiConfiguration = .magpie
                }
                desktopScopeDetail = "演示：API 桌面不纳入订阅守护；CLI 同步与核验单独检查默认订阅配置。"
            }
            if CommandLine.arguments.contains("--demo-unmanaged") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewUnmanaged") as? Bool == true {
                desktopManaged = false; desktopScopeDetail = "演示：当前桌面未保护，确认纳入前不接管。"
            }
            if CommandLine.arguments.contains("--demo-unprotected") {
                enabled = false; guardOnline = false; lastDecision = SafetyDecision(.disabled)
                status = "演示：保护未启用。"
            }
        } else {
            if let config = try? files.loadConfig() { country = config.expectedCountry; mode = config.proxyMode }
            refreshStatus()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshStatus() }
            }
        }
    }
    deinit { timer?.invalidate() }

    func clearOperationError() { operationError = nil }

    private func applySaved(_ config: SafetyConfig?) {
        activeCountry = config?.expectedCountry
        activeProxyMode = config?.proxyMode
    }

    /// Called only after the UI's explicit subscription-mode confirmation.
    func protectCurrentDesktop() async {
        guard !working else { return }
        operationError = nil
        if demo {
            guard enabled, guardOnline, desktopScope == .subscription else {
                operationError = "演示：保护服务或订阅配置未就绪。"; return
            }
            desktopManaged = true; desktopScopeDetail = "演示：当前订阅桌面已由用户确认纳入保护。"; return
        }
        guard let config = try? files.loadConfig(), config.enabled,
              await worker.registered(), files.loadReceipt()?.isFresh(for: config) == true else {
            operationError = "保护服务或配置尚未就绪，未改变当前桌面的保护范围。"; return
        }
        guard !working, (try? files.loadConfig()) == config else { return }
        working = true; defer { working = false }
        do {
            let record = try currentSubscriptionDesktopRecord()
            try files.save(record, to: files.managedDesktopURL)
            guard files.loadManagedDesktop() == record, managedDesktopApplication(files) != nil else {
                throw SafetyError("桌面进程或配置已变化，尚未确认保护范围，请重试。")
            }
            await refreshStatusAsync(afterOperation: true)
        } catch { operationError = error.localizedDescription }
    }

    func refreshScope() {
        guard !demo else { return }
        desktopScope = DesktopModeInspector.read(support: files.directory.deletingLastPathComponent())
        apiConfiguration = APIConfigurationInspector.read(support: files.directory.deletingLastPathComponent(), scope: desktopScope)
        desktopManaged = managedDesktopApplication(files) != nil
        switch desktopScope {
        case .api: desktopScopeDetail = "API 配置不纳入订阅桌面守护；从原工具启动的进程不会被接管。"
        case .unknown: desktopScopeDetail = "无法确认订阅配置，桌面入口暂停；不会按进程名关闭现有客户端。"
        case .subscription:
            desktopScopeDetail = desktopManaged ? "只管理本候选入口记录的订阅桌面进程。" : "订阅配置已识别；当前桌面未保护，确认纳入前不接管。"
        }
    }

    func refreshStatus() {
        guard !demo else { return }
        // Expiry remains visible even if a service query is still waiting off the UI actor.
        if let config = try? files.loadConfig(), config.enabled,
           files.loadReceipt()?.isFresh(for: config) != true {
            guardOnline = false; lastDecision = SafetyDecision(.staleReceipt); status = lastDecision.message
        }
        guard !refreshing, !working else { return }
        refreshing = true
        Task { await refreshStatusAsync(); refreshing = false }
    }
    private func refreshStatusAsync(afterOperation: Bool = false) async {
        guard !demo, !working || afterOperation else { return }
        let saved = try? files.loadConfig()
        if let saved {
            if files.loadReceipt()?.isFresh(for: saved) != true { guardOnline = false }
        } else { guardOnline = false }
        let registered = await worker.registered()
        guard !working || afterOperation else { return }
        let latest = try? files.loadConfig()
        guard latest == saved else { applySaved(latest); guardOnline = false; return }
        refreshScope(); applySaved(saved)
        guard let config = saved else {
            enabled = registered; guardOnline = false
            lastDecision = SafetyDecision(registered || FileManager.default.fileExists(atPath: files.configURL.path) ? .invalidConfig : .disabled)
            status = lastDecision.message; return
        }
        enabled = config.enabled
        guard config.enabled else {
            guardOnline = false; lastDecision = SafetyDecision(.disabled); status = lastDecision.message; return
        }
        guard registered else {
            guardOnline = false; lastDecision = SafetyDecision(.guardUnavailable); status = lastDecision.message; return
        }
        guard let receipt = files.loadReceipt(), receipt.isFresh(for: config) else {
            guardOnline = false; lastDecision = SafetyDecision(.staleReceipt); status = lastDecision.message; return
        }
        guardOnline = true
        lastDecision = receipt.termination == "failed" ? SafetyDecision(.terminationFailed) : receipt.decision
        status = lastDecision.allowed ? "网络门禁已就绪 · 目标 \(config.expectedCountry)" : lastDecision.message
    }

    func enable() async {
        guard !working else { return }
        operationError = nil
        if demo {
            do {
                let config = try SafetyConfig(enabled: true, expectedCountry: country, proxyMode: mode).validated()
                if CommandLine.arguments.contains("--demo-operation-error") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewOperationError") as? Bool == true {
                    throw SafetyError("演示：配置无法写入；保护设置没有改变。")
                }
                country = config.expectedCountry; activeCountry = config.expectedCountry; activeProxyMode = config.proxyMode
                enabled = true; guardOnline = true; lastDecision = SafetyPolicy.evaluate(config, demoNetwork)
                status = "演示：" + lastDecision.message
            } catch { operationError = error.localizedDescription }
            return
        }
        working = true; defer { working = false }
        do {
            let config = try SafetyConfig(enabled: true, expectedCountry: country, proxyMode: mode).validated()
            try await worker.enable(config)
            country = config.expectedCountry
            await refreshStatusAsync(afterOperation: true)
        } catch {
            await refreshStatusAsync(afterOperation: true)
            operationError = error.localizedDescription
        }
    }
    func disable() {
        guard !working else { return }
        operationError = nil
        if demo { enabled = false; guardOnline = false; lastDecision = SafetyDecision(.disabled); status = "演示：保护已停止"; return }
        working = true
        Task {
            defer { working = false }
            do { try await worker.disable(); await refreshStatusAsync(afterOperation: true) }
            catch { await refreshStatusAsync(afterOperation: true); operationError = error.localizedDescription }
        }
    }

    /// Read-only diagnosis of the form's inputs; never starts the guard or changes its decision.
    func checkNow() async {
        guard !checking, !working else { return }
        checking = true
        defer { checking = false }
        let config: SafetyConfig
        do { config = try SafetyConfig(enabled: true, expectedCountry: country, proxyMode: mode).validated() }
        catch {
            lastCheckSummary = error.localizedDescription
            let checkedAt = Date()
            lastCheckedAt = checkedAt
            lastCheckReport = ManualNetworkCheck(checkedAt: checkedAt, targetCountry: nil, observation: nil,
                                                decision: SafetyDecision(.invalidConfig), validationMessage: error.localizedDescription)
            return
        }
        // Fictional preview only: expose the loading state without interrupting
        // the real proxy or using a real account as a failure fixture.
        if demo && Bundle.main.object(forInfoDictionaryKey: "CSPreviewSlowNetworkCheck") as? Bool == true {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let observation = demo ? demoNetwork : await NetworkProbe().observe(mode: config.proxyMode)
        let decision = SafetyPolicy.evaluate(config, observation)
        let route = observation.routesDisagree ? "各域名国家不一致" : (observation.country ?? "未知")
        lastCheckSummary = "\(decision.allowed ? "网络检测通过" : "网络检测未通过") · 本次目标 \(config.expectedCountry)\n"
            + "代理：\(observation.proxyConnected ? "已连接" : "未连接")；TUN：\(observation.tunOnline ? "在线" : "未检测到")；出口国家：\(route)。\n"
            + "仅按当前输入检测；未保存设置或改变保护开关。"
        let checkedAt = Date()
        lastCheckedAt = checkedAt
        lastCheckReport = ManualNetworkCheck(checkedAt: checkedAt, targetCountry: config.expectedCountry,
                                            observation: observation, decision: decision, validationMessage: nil)
    }
    func preflight(target: ProtectedTarget = .desktop) async -> SafetyDecision {
        if demo {
            if target == .desktop && desktopScope != .subscription { return SafetyDecision(.unsupportedMode) }
            return lastDecision
        }
        func finish(_ decision: SafetyDecision) -> SafetyDecision {
            lastDecision = decision; status = decision.message; return decision
        }
        guard !working else { return SafetyDecision(.guardUnavailable) }
        guard let config = try? files.loadConfig() else {
            let exists = FileManager.default.fileExists(atPath: files.configURL.path)
            let registered = await worker.registered()
            applySaved(nil)
            return finish(SafetyDecision(exists || registered ? .invalidConfig : .disabled))
        }
        applySaved(config); enabled = config.enabled; refreshScope()
        guard config.enabled else { return finish(SafetyDecision(.disabled)) }
        if target == .desktop && desktopScope != .subscription { return finish(SafetyDecision(.unsupportedMode)) }
        guard await worker.registered() else { guardOnline = false; return finish(SafetyDecision(.guardUnavailable)) }
        guardOnline = files.loadReceipt()?.isFresh(for: config) == true
        let network = await NetworkProbe().observe(mode: config.proxyMode)
        guard (try? files.loadConfig()) == config else { applySaved(nil); return finish(SafetyDecision(.invalidConfig)) }
        refreshScope()
        let registered = await worker.registered(), receipt = files.loadReceipt()
        guardOnline = registered && receipt?.isFresh(for: config) == true
        return finish(LaunchGate.evaluate(config: config, registered: registered, receipt: receipt,
                                         network: network, target: target, desktopScope: desktopScope))
    }
}
