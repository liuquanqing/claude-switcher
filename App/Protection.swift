import Foundation
import SwiftUI
import SwitcherCore

@MainActor
final class ProtectionController: ObservableObject {
    @Published var country = "SG"
    @Published var mode: ProxyMode = .shadowrocket
    @Published var status = "保护未启用"
    @Published var enabled = false
    @Published var working = false
    @Published var lastDecision = SafetyDecision(.disabled)
    private let demo: Bool
    private var timer: Timer?
    let files: SafetyFiles
    let service: GuardService

    init(demo: Bool = false) {
        self.demo = demo
        files = SafetyFiles(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeSwitcher"))
        service = GuardService(files: files, helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClaudeGuard"))
        if demo {
            enabled = true; status = "守卫在线 · 目标 SG · 退出界面后继续保护"
            lastDecision = SafetyDecision(.allowed, expected: "SG", observed: "SG")
            if CommandLine.arguments.contains("--demo-blocked") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewBlocked") as? Bool == true {
                lastDecision = SafetyDecision(.countryMismatch, expected: "SG", observed: "JP")
                status = "演示：出口 JP 与目标 SG 不一致，已阻止打开。"
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
        if FileManager.default.fileExists(atPath: files.configURL.path), (try? files.loadConfig()) == nil {
            enabled = service.registered; lastDecision = SafetyDecision(.invalidConfig)
            status = "保护配置无效；已注册的守卫会按失败处理，请保存配置或明确停止保护。"; return
        }
        guard let config = try? files.loadConfig(), config.enabled else {
            enabled = false; lastDecision = SafetyDecision(.disabled); status = "保护未启用 · 打开与切换将被拦截"; return
        }
        enabled = true
        guard service.registered else {
            lastDecision = SafetyDecision(.guardUnavailable); status = lastDecision.message; return
        }
        guard let receipt = files.loadReceipt(), receipt.isFresh(for: config) else {
            lastDecision = SafetyDecision(.staleReceipt); status = lastDecision.message; return
        }
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
                enabled = true; lastDecision = SafetyDecision(.allowed, expected: country, observed: country)
                status = "演示：守卫在线 · 目标 \(country)"
            } catch { lastDecision = SafetyDecision(.invalidConfig); status = error.localizedDescription }
            return
        }
        guard !working else { return }
        working = true; defer { working = false }
        do {
            let config = try SafetyConfig(enabled: true, expectedCountry: country, proxyMode: mode).validated()
            try service.enable(config)
            country = config.expectedCountry
            refreshStatus()
        } catch { status = error.localizedDescription; lastDecision = SafetyDecision(.guardUnavailable) }
    }
    func disable() {
        if demo { enabled = false; lastDecision = SafetyDecision(.disabled); status = "演示：保护已停止"; return }
        guard !working else { return }
        do { try service.disable(); refreshStatus() }
        catch { status = error.localizedDescription }
    }
    func preflight() async -> SafetyDecision {
        if demo { return lastDecision }
        func finish(_ decision: SafetyDecision) -> SafetyDecision {
            lastDecision = decision; status = decision.message; return decision
        }
        guard let config = try? files.loadConfig() else { return finish(SafetyDecision(.invalidConfig)) }
        enabled = config.enabled
        guard config.enabled else { return finish(SafetyDecision(.disabled)) }
        guard service.registered else { return finish(SafetyDecision(.guardUnavailable)) }
        let network = await NetworkProbe().observe(mode: config.proxyMode)
        guard (try? files.loadConfig()) == config else { return finish(SafetyDecision(.invalidConfig)) }
        let decision = LaunchGate.evaluate(config: config, registered: service.registered,
                                          receipt: files.loadReceipt(), network: network)
        return finish(decision)
    }
}
