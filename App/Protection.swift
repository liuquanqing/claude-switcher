import Foundation
import SwiftUI
import SwitcherCore

@MainActor
final class ProtectionController: ObservableObject {
    @Published var country = "SG"
    @Published private(set) var activeCountry: String?
    @Published var mode: ProxyMode = .shadowrocket
    @Published var status = "保护未启用"
    @Published var enabled = false
    @Published var guardOnline = false
    @Published var working = false
    @Published var lastDecision = SafetyDecision(.disabled)
    private let demo: Bool
    private var timer: Timer?
    let files: SafetyFiles
    let service: GuardService
    var exitStatusText: String {
        if !enabled { return "保护未启用" }
        return guardOnline ? "后台保护继续运行" : "保护状态待确认"
    }

    init(demo: Bool = false) {
        self.demo = demo
        files = SafetyFiles(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeSwitcher"))
        service = GuardService(files: files, helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClaudeGuard"))
        if demo {
            enabled = true; guardOnline = true; activeCountry = "SG"; status = "守卫在线 · 目标 SG · 退出界面后继续保护"
            lastDecision = SafetyDecision(.allowed, expected: "SG", observed: "SG")
            if CommandLine.arguments.contains("--demo-blocked") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewBlocked") as? Bool == true {
                lastDecision = SafetyDecision(.countryMismatch, expected: "SG", observed: "JP")
                status = "演示：出口 JP 与目标 SG 不一致，已阻止打开。"
            }
            if CommandLine.arguments.contains("--demo-guard-unknown") {
                guardOnline = false; lastDecision = SafetyDecision(.staleReceipt)
                status = "演示：守卫回执过期，保护状态待确认。"
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

    func refreshStatus() {
        guard !demo else { return }
        guardOnline = false
        let savedConfig = try? files.loadConfig()
        activeCountry = savedConfig?.expectedCountry
        if FileManager.default.fileExists(atPath: files.configURL.path), savedConfig == nil {
            enabled = service.registered; lastDecision = SafetyDecision(.invalidConfig)
            status = "保护配置无效；已注册的守卫会按失败处理，请保存配置或明确停止保护。"; return
        }
        guard let config = savedConfig, config.enabled else {
            enabled = false; lastDecision = SafetyDecision(.disabled); status = "保护未启用 · 打开与切换将被拦截"; return
        }
        enabled = true
        guard service.registered else {
            lastDecision = SafetyDecision(.guardUnavailable); status = lastDecision.message; return
        }
        guard let receipt = files.loadReceipt(), receipt.isFresh(for: config) else {
            lastDecision = SafetyDecision(.staleReceipt); status = lastDecision.message; return
        }
        guardOnline = true
        lastDecision = receipt.termination == "failed" ? SafetyDecision(.terminationFailed) : receipt.decision
        status = lastDecision.allowed ? "守卫在线 · 目标 \(config.expectedCountry) · 退出界面后继续保护" : lastDecision.message
        if receipt.termination == "closed" { status += " · Claude 已关闭" }
        else if !lastDecision.allowed && receipt.termination == "not_running" { status += " · Claude 未运行" }
    }

    func enable() async {
        if demo {
            do {
                let config = try SafetyConfig(enabled: true, expectedCountry: country, proxyMode: mode).validated()
                country = config.expectedCountry
                activeCountry = config.expectedCountry
                enabled = true; guardOnline = true; lastDecision = SafetyDecision(.allowed, expected: country, observed: country)
                status = "演示：守卫在线 · 目标 \(country)"
            } catch { guardOnline = false; lastDecision = SafetyDecision(.invalidConfig); status = error.localizedDescription }
            return
        }
        guard !working else { return }
        working = true; defer { working = false }
        do {
            let config = try SafetyConfig(enabled: true, expectedCountry: country, proxyMode: mode).validated()
            try service.enable(config)
            country = config.expectedCountry
            refreshStatus()
        } catch { refreshStatus(); status = error.localizedDescription; lastDecision = SafetyDecision(.guardUnavailable) }
    }
    func disable() {
        if demo { enabled = false; guardOnline = false; lastDecision = SafetyDecision(.disabled); status = "演示：保护已停止"; return }
        guard !working else { return }
        do { try service.disable(); refreshStatus() }
        catch { refreshStatus(); status = error.localizedDescription }
    }
    func preflight() async -> SafetyDecision {
        if demo { return lastDecision }
        guardOnline = false
        func finish(_ decision: SafetyDecision) -> SafetyDecision {
            lastDecision = decision; status = decision.message; return decision
        }
        guard let config = try? files.loadConfig() else { activeCountry = nil; return finish(SafetyDecision(.invalidConfig)) }
        activeCountry = config.expectedCountry
        enabled = config.enabled
        guard config.enabled else { return finish(SafetyDecision(.disabled)) }
        guard service.registered else { return finish(SafetyDecision(.guardUnavailable)) }
        // A foreground network check does not itself make a fresh, registered guard offline.
        guardOnline = files.loadReceipt()?.isFresh(for: config) == true
        let network = await NetworkProbe().observe(mode: config.proxyMode)
        guard (try? files.loadConfig()) == config else { activeCountry = nil; return finish(SafetyDecision(.invalidConfig)) }
        let registered = service.registered, receipt = files.loadReceipt()
        guardOnline = registered && receipt?.isFresh(for: config) == true
        let decision = LaunchGate.evaluate(config: config, registered: registered,
                                          receipt: receipt, network: network)
        return finish(decision)
    }
}
