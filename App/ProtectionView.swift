import SwiftUI
import SwitcherCore

struct ProtectionStrip: View {
    @ObservedObject var controller: ProtectionController
    let busy: Bool
    let openClaude: () -> Void
    @State private var confirmStop = false
    @State private var showSettings = false

    private var passing: Bool { controller.enabled && controller.lastDecision.allowed }
    private var statusColor: Color {
        if controller.working || !controller.enabled { return .sub }
        return passing ? .good : .warn
    }
    private var statusTitle: String {
        if controller.working { return "正在更新保护设置" }
        if !controller.enabled { return "后台保护未启用" }
        return passing ? "独立后台保护中" : "保护需要检查"
    }
    private var statusIcon: String {
        if controller.working { return "arrow.triangle.2.circlepath" }
        if !controller.enabled { return "shield" }
        return passing ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
    }
    private var modeDetail: String {
        switch controller.mode {
        case .shadowrocket: return "Shadowrocket 需显示已连接；仅识别 198.18.* TUN 地址。"
        case .auto: return "自动模式仅识别 198.18.* TUN 地址，不修改系统代理。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon).font(.system(size: 13, weight: .semibold))
                    .foregroundColor(statusColor).frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(statusColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.txt)
                    Text(passing ? controller.lastDecision.message : controller.status).font(.system(size: 10.5))
                        .foregroundColor(passing ? .sub : statusColor)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if controller.enabled {
                    Button(showSettings ? "收起" : "设置") { showSettings.toggle() }
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.sub).padding(.horizontal, 7).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.stroke.opacity(0.65)))
                        .help(showSettings ? "收起保护设置" : "配置代理、TUN 与出口国家")
                }
            }

            if showSettings || !controller.enabled {
                Divider().background(Color.stroke.opacity(0.75))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("出口国家").font(.system(size: 10.5)).foregroundColor(.sub)
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
                        .buttonStyle(.plain).opacity(busy || controller.working ? 0.55 : 1)
                    }
                    .disabled(busy || controller.working)
                    Text(modeDetail).font(.system(size: 9.5)).foregroundColor(.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("启动与切换前检查代理、TUN 和出口国家；失败或未知均不放行。仅保护桌面版，后台检查存在间隔。")
                        .font(.system(size: 9.5)).foregroundColor(.sub.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().background(Color.stroke.opacity(0.75))
            HStack(spacing: 9) {
                Text(controller.enabled ? "退出界面，后台保护继续" : "退出界面不改变保护状态")
                    .font(.system(size: 9.5)).foregroundColor(.sub)
                Spacer(minLength: 4)
                if controller.enabled {
                    Button("停止保护") { confirmStop = true }
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.bad).disabled(busy || controller.working)
                        .help("独立停止后台守卫，需要再次确认")
                }
                Button(action: openClaude) {
                    Text("打开 Claude").font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundColor(.white)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.claude))
                }
                .buttonStyle(.plain).disabled(busy || controller.working)
                .opacity(busy || controller.working ? 0.45 : 1)
                .help("打开前重新检查代理、TUN 和出口国家")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.stroke.opacity(0.32), lineWidth: 1))
        .confirmationDialog("停止后台保护？独立守卫将停用，切换器也不再放行打开或切换 Claude。仅退出界面不会停止保护。",
                            isPresented: $confirmStop) {
            Button("确认停止保护", role: .destructive) { controller.disable() }
            Button("取消", role: .cancel) {}
        }
    }
}
