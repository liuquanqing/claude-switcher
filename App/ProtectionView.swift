import SwiftUI
import SwitcherCore

struct ProtectionStrip: View {
    @ObservedObject var controller: ProtectionController
    let busy: Bool
    let openClaude: () -> Void
    @State private var confirmStop = false
    @State private var showSettings = false

    private var statusColor: Color {
        if controller.working || !controller.enabled { return .sub }
        if !controller.guardOnline { return .warn }
        if controller.lastDecision.reason == .terminationFailed { return .bad }
        return controller.lastDecision.allowed ? .good : .warn
    }
    private var statusTitle: String {
        if controller.working { return "正在更新设置" }
        if !controller.enabled { return "保护未启用" }
        if !controller.guardOnline { return "保护状态待确认" }
        if controller.lastDecision.reason == .terminationFailed { return "急停失败" }
        return controller.lastDecision.allowed ? "后台保护中" : "已拦截"
    }
    private var statusIcon: String {
        if controller.working { return "arrow.triangle.2.circlepath" }
        if !controller.enabled { return "shield" }
        if !controller.guardOnline { return "exclamationmark.triangle.fill" }
        return controller.lastDecision.allowed ? "checkmark.shield.fill" : "shield.lefthalf.filled"
    }
    private var shortStatus: String? {
        if controller.working { return nil }
        if !controller.enabled { return "打开与切换将被拦截；可在设置中启用保护。" }
        if !controller.guardOnline || !controller.lastDecision.allowed { return controller.status }
        return nil
    }
    private var modeDetail: String {
        switch controller.mode {
        case .shadowrocket: return "Shadowrocket 需显示已连接；仅识别 198.18.* TUN 地址。"
        case .auto: return "自动模式仅识别 198.18.* TUN 地址，不修改系统代理。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon).font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor).frame(width: 16, height: 16)
                Text(statusTitle).font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(statusColor).lineLimit(1)
                Text("目标 \(controller.activeCountry ?? "未设置")").font(.system(size: 10.5)).foregroundColor(.sub)
                    .lineLimit(1).frame(width: 64, alignment: .leading)
                Spacer(minLength: 4)
                Button(action: openClaude) {
                    Text("打开 Claude").font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.sub).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.stroke.opacity(0.35)))
                }
                .buttonStyle(.plain).disabled(busy || controller.working)
                .opacity(busy || controller.working ? 0.45 : 1)
                .help("打开前重新检查代理、TUN 和出口国家")
                Button(showSettings ? "收起" : "设置") { showSettings.toggle() }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.sub)
                    .help(showSettings ? "收起保护设置" : "配置代理、TUN 与出口国家")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.card.opacity(0.72)))

            if let shortStatus, !showSettings {
                Text(shortStatus).font(.system(size: 10)).foregroundColor(statusColor)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            if showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.status).font(.system(size: 10.5))
                        .foregroundColor(controller.guardOnline && controller.lastDecision.allowed ? .sub : statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text("目标国家").font(.system(size: 10.5)).foregroundColor(.sub)
                        TextField("SG", text: $controller.country)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center).foregroundColor(.txt)
                            .padding(.vertical, 5).frame(width: 44)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.bg))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stroke, lineWidth: 1))
                            .help("两位国家代码，例如 SG；保存并启用后生效")
                        Picker("代理模式", selection: $controller.mode) {
                            Text("Shadowrocket").tag(ProxyMode.shadowrocket)
                            Text("自动识别 TUN").tag(ProxyMode.auto)
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 145)
                        Spacer(minLength: 0)
                    }
                    .disabled(busy || controller.working)
                    Text(modeDetail).font(.system(size: 9.5)).foregroundColor(.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("启动与切换前检查代理、TUN 和出口国家；失败或未知均不放行。仅保护桌面版，后台检查存在间隔。")
                        .font(.system(size: 9.5)).foregroundColor(.sub.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button { Task { await controller.enable() } } label: {
                            HStack(spacing: 5) {
                                if controller.working { ProgressView().controlSize(.small) }
                                Text(controller.enabled ? "保存并启用" : "启用保护")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundColor(.white)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.claude))
                        }
                        .buttonStyle(.plain).disabled(busy || controller.working)
                        .opacity(busy || controller.working ? 0.55 : 1)
                        if controller.enabled {
                            Button("停止保护") { confirmStop = true }
                                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.bad).disabled(busy || controller.working)
                                .help("独立停止后台守卫，需要再次确认")
                        }
                        Spacer()
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.stroke.opacity(0.32), lineWidth: 1))
            }
        }
        .confirmationDialog("停止后台保护？独立守卫将停用，切换器也不再放行打开或切换 Claude。仅退出界面不会停止保护。",
                            isPresented: $confirmStop) {
            Button("确认停止保护", role: .destructive) { controller.disable() }
            Button("取消", role: .cancel) {}
        }
    }
}
