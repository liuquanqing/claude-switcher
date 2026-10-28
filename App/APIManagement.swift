import AppKit
import SwitcherCore

@MainActor extension Store {
    func openAPIManager() async {
        let configured = protection.apiConfiguration
        if isDemo {
            banner = configured.managerBundleID == nil ? "演示：来源未确认，未调用任何管理器。"
                : "演示：打开原 API 管理器；退出 API 接管由原工具完成，此处不改模式或密钥。"
            return
        }
        let actual = APIConfigurationInspector.read(support: support, scope: DesktopModeInspector.read(support: support))
        guard actual == configured, let identifier = actual.managerBundleID else {
            banner = "API 配置来源未确认或已变化，未调用任何工具。"; protection.refreshStatus(); return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            banner = "未找到匹配的 API 管理器，请继续使用原来的工具管理模式。"; return
        }
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        catch { banner = "API 管理器未能打开；配置未改动。" }
    }
}
