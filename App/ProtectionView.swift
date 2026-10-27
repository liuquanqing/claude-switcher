import SwiftUI
import SwitcherCore

struct TerminalProtectionCard: View {
    @ObservedObject var store: Store
    @ObservedObject var controller: ProtectionController
    let busy: Bool
    @State private var confirmStop = false
    @State private var showSettings = false
    @State private var showCheckDetails = false
    @State private var showCheckHelp = false

    private enum CheckDetailStatus {
        case passed, failed, unknown, notRun

        var color: Color {
            switch self {
            case .passed: return .good
            case .failed: return .bad
            case .unknown: return .warn
            case .notRun: return .sub
            }
        }
        var icon: String {
            switch self {
            case .passed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .unknown: return "questionmark.circle"
            case .notRun: return "minus.circle"
            }
        }
    }

    private struct CheckDetailItem {
        let title: String
        let icon: String
        let value: String
        let status: CheckDetailStatus
    }

    private var checkSummary: String {
        guard let report = controller.lastCheckReport else { return "尚未执行" }
        if report.validationMessage != nil { return "参数无效" }
        guard report.observation != nil else { return "检查未完成" }
        return report.passed ? "网络通过" : "网络未通过"
    }
    private var checkSummaryColor: Color {
        guard let report = controller.lastCheckReport else { return .sub }
        if report.validationMessage != nil { return .warn }
        guard report.observation != nil else { return .sub }
        return report.passed ? .good : .bad
    }
    private var checkDetailItems: [CheckDetailItem] {
        let observation = controller.lastCheckReport?.observation
        return [
            connectionDetail(title: "代理", icon: "network",
                             online: observation?.proxyConnected,
                             connected: "已连接", disconnected: "未连接"),
            connectionDetail(title: "TUN", icon: "dot.radiowaves.left.and.right",
                             online: observation?.tunOnline,
                             connected: "在线", disconnected: "离线"),
            countryDetail
        ]
    }
    private var countryDetail: CheckDetailItem {
        guard let report = controller.lastCheckReport, let observation = report.observation else {
            return CheckDetailItem(title: "出口国家", icon: "globe", value: "未检查", status: .notRun)
        }
        if observation.routesDisagree {
            return CheckDetailItem(title: "出口国家", icon: "globe", value: "路由不一致", status: .failed)
        }
        guard let country = observation.country, !country.isEmpty else {
            return CheckDetailItem(title: "出口国家", icon: "globe", value: "未知", status: .unknown)
        }
        guard let target = report.targetCountry else {
            return CheckDetailItem(title: "出口国家", icon: "globe", value: country, status: .unknown)
        }
        let matches = country.uppercased() == target.uppercased()
        return CheckDetailItem(title: "出口国家", icon: "globe",
                               value: matches ? "\(country) · 符合目标" : "\(country) · 目标 \(target)",
                               status: matches ? .passed : .failed)
    }

    private func connectionDetail(title: String, icon: String, online: Bool?,
                                  connected: String, disconnected: String) -> CheckDetailItem {
        guard let online else {
            return CheckDetailItem(title: title, icon: icon, value: "未检查", status: .notRun)
        }
        return CheckDetailItem(title: title, icon: icon, value: online ? connected : disconnected,
                               status: online ? .passed : .failed)
    }
    private func checkDetailRow(_ item: CheckDetailItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .frame(width: 16, alignment: .leading)
            Text(item.title)
                .foregroundColor(.txt)
                .frame(width: 58, alignment: .leading)
            Spacer(minLength: 8)
            Text(item.value)
                .lineLimit(1)
            Image(systemName: item.status.icon)
                .frame(width: 12)
        }
        .font(.system(size: 10.5))
        .foregroundColor(item.status.color)
    }

    private var checkDetailsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = controller.lastCheckReport?.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9.5)).foregroundColor(.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(checkDetailItems, id: \.title) { item in
                checkDetailRow(item)
            }
        }
        .padding(.top, 8)
    }
    private var checkHelpContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“仅检查网络”只诊断，不开启保护或打开 Claude；“检查并打开”会重新检查必要条件，满足门禁后打开当前账号。")
                .fixedSize(horizontal: false, vertical: true)
            Text(modeDetail)
                .fixedSize(horizontal: false, vertical: true)
            Text("启动与切换前检查代理、TUN 和出口国家；失败或未知均不放行。仅保护桌面版，后台检查存在间隔。")
                .fixedSize(horizontal: false, vertical: true)
            Text("配置只读时仍可仅检查网络；启用保护与保存设置需要写入配置。")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("辅助体检")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.txt)
            Link("IP / WebRTC 体检（第三方）↗", destination: URL(string: "https://ip.net.coffee/claude/")!)
                .font(.system(size: 10.5, weight: .medium)).foregroundColor(.claude)
            Text("第三方网页，结果仅供参考；不抓取评分，不作为打开放行的硬门禁。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 9.5)).foregroundColor(.sub)
        .padding(.top, 8)
    }

    private var protectionEnabled: Binding<Bool> {
        Binding(get: { controller.enabled }, set: { requested in
            if requested {
                Task { await controller.enable() }
            } else {
                confirmStop = true
            }
        })
    }

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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                TerminalStrip(store: store)
                Rectangle().fill(Color.stroke.opacity(0.55)).frame(width: 1, height: 36)
                Button { showSettings.toggle() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: statusIcon).font(.system(size: 12, weight: .semibold))
                                .frame(width: 16, height: 16)
                            Text(statusTitle).font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .foregroundColor(statusColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            Text("目标 \(controller.activeCountry ?? "未设置")")
                                .font(.system(size: 10)).foregroundColor(.sub).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(showSettings ? "收起" : "设置")
                                .font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
                            Image(systemName: showSettings ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .semibold)).foregroundColor(.sub)
                                .frame(width: 8)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(width: 154)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showSettings ? "收起保护设置" : "配置代理、TUN 与出口国家")
            }

            if let shortStatus, !showSettings {
                Rectangle().fill(Color.stroke.opacity(0.4)).frame(height: 1)
                Text(shortStatus).font(.system(size: 10)).foregroundColor(statusColor)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(shortStatus)
            }

            if showSettings {
                Rectangle().fill(Color.stroke.opacity(0.4)).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("后台保护", isOn: protectionEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.txt)
                        .disabled(busy || controller.working)
                    if controller.activeCountry == nil {
                        Text("首次使用：设置目标国家和代理模式，再开启后台保护。")
                            .font(.system(size: 9.5)).foregroundColor(.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Text("目标国家").font(.system(size: 10.5)).foregroundColor(.sub)
                        TextField("SG", text: $controller.country)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center).foregroundColor(.txt)
                            .padding(.vertical, 5).frame(width: 44)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.bg))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stroke, lineWidth: 1))
                            .help("两位国家代码，例如 SG；保存设置或开启保护后生效")
                        Picker("代理模式", selection: $controller.mode) {
                            Text("Shadowrocket").tag(ProxyMode.shadowrocket)
                            Text("自动识别 TUN").tag(ProxyMode.auto)
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 145)
                        Spacer(minLength: 0)
                    }
                    .disabled(busy || controller.working || controller.checking)
                    HStack(spacing: 10) {
                        Button { Task { await controller.checkNow() } } label: {
                            HStack(spacing: 5) {
                                if controller.checking { ProgressView().controlSize(.small) }
                                Text(controller.checking ? "检查中…" : "仅检查网络")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundColor(.claude)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.claude.opacity(0.12)))
                        }
                        .buttonStyle(.plain).disabled(busy || controller.working || controller.checking)
                        .opacity(busy || controller.working || controller.checking ? 0.55 : 1)
                        .help("只诊断网络，不开启保护，也不打开 Claude")
                        if controller.enabled {
                            Button("保存设置") { Task { await controller.enable() } }
                                .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundColor(.white)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.claude))
                                .disabled(busy || controller.working)
                                .opacity(busy || controller.working ? 0.55 : 1)
                        }
                        Spacer()
                    }
                    HStack(spacing: 5) {
                        Text("最近检测：").foregroundColor(.sub)
                        Text(checkSummary).foregroundColor(checkSummaryColor)
                        Spacer(minLength: 4)
                        if let date = controller.lastCheckReport?.checkedAt {
                            Text(date, style: .time).foregroundColor(.sub)
                        }
                    }
                    .font(.system(size: 9.5)).lineLimit(1)
                    DisclosureGroup("检测详情", isExpanded: $showCheckDetails) {
                        checkDetailsContent
                    }
                    .font(.system(size: 10.5, weight: .medium)).foregroundColor(.sub)
                    DisclosureGroup("检查说明", isExpanded: $showCheckHelp) {
                        checkHelpContent
                    }
                    .font(.system(size: 10.5, weight: .medium)).foregroundColor(.sub)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
        .confirmationDialog("停止后台保护？独立守卫将停用，切换器也不再放行打开或切换 Claude。仅退出界面不会停止保护。",
                            isPresented: $confirmStop) {
            Button("确认停止保护", role: .destructive) { controller.disable() }
            Button("取消", role: .cancel) {}
        }
    }
}
