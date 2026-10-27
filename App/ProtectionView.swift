import SwiftUI
import SwitcherCore

struct TerminalProtectionCard: View {
    @ObservedObject var store: Store
    @ObservedObject var controller: ProtectionController
    let busy: Bool
    @State private var confirmStop = false
    @State private var confirmProtectCurrentDesktop = false
    @State private var showSettings = false
    @State private var showCheckDetails = false
    @State private var showCheckHelp = false
    @State private var showProxyHelp = false

    private enum CheckDetailStatus {
        case passed, failed, unknown, notRun

        var color: Color {
            switch self {
            case .passed: return .good
            case .failed: return .bad
            case .unknown: return .sub
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
                .foregroundColor(.sub)
                .frame(width: 16, alignment: .leading)
            Text(item.title)
                .foregroundColor(.txt)
                .frame(width: 58, alignment: .leading)
            Text(item.value)
                .foregroundColor(item.status.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: item.status.icon)
                .foregroundColor(item.status.color)
                .frame(width: 12)
        }
        .font(.system(size: 10.5))
    }

    private var checkDetailsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = controller.lastCheckReport?.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9.5)).foregroundColor(.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            ForEach(checkDetailItems, id: \.title) { item in
                checkDetailRow(item)
                    .padding(.vertical, 4)
                if item.title != checkDetailItems.last?.title {
                    Divider()
                        .opacity(0.6)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(.top, 6)
    }
    private var checkHelpContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                checkActionRow(title: "仅检查网络",
                               detail: "按当前输入诊断；不保存、不启用保护、不打开 Claude。")
                checkActionRow(title: "检查并打开",
                               detail: "按已保存配置复查必要条件，满足后打开当前账号。")
            }
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 6) {
                Text(desktopScopeSummary)
                    .foregroundColor(desktopScopeColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text("后台检查存在间隔；启动与切换前检查代理、TUN 和出口国家，失败或未知均不放行。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("高级信息") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(desktopScopeHelp)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("配置只读时仍可仅检查网络；启用保护与保存设置需要写入配置。")
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.6)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("辅助体检")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.txt)
                        Link("IP / WebRTC 体检（第三方）↗", destination: URL(string: "https://ip.net.coffee/claude/")!)
                            .font(.system(size: 10.5, weight: .medium)).foregroundColor(.claude)
                        Text("第三方网页，结果仅供参考；不抓取评分，不作为打开放行的硬门禁。")
                            .font(.system(size: 9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 10, weight: .medium)).foregroundColor(.sub)
        }
        .font(.system(size: 10)).foregroundColor(.sub)
        .lineSpacing(2)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkActionRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.txt)
                .frame(width: 72, alignment: .leading)
            Text(detail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var proxyHelpContent: some View {
        Text(modeDetail)
            .font(.system(size: 9.5)).foregroundColor(.sub)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var desktopScopeShort: String {
        switch controller.desktopScope {
        case .subscription: return "范围：订阅桌面"
        case .api: return "API 模式"
        case .unknown: return "桌面范围待确认"
        }
    }

    private var desktopScopeSummary: String {
        switch controller.desktopScope {
        case .subscription: return "保护范围：本入口启动或用户确认的订阅桌面"
        case .api: return "保护范围：桌面 API 配置未纳入订阅守护"
        case .unknown: return "保护范围：桌面配置待确认，不视为已纳入"
        }
    }

    private var desktopScopeColor: Color {
        switch controller.desktopScope {
        case .subscription: return .sub
        case .api, .unknown: return .warn
        }
    }

    private var desktopScopeHelp: String {
        let summary: String
        switch controller.desktopScope {
        case .subscription:
            summary = "从本入口启动的订阅桌面会自动纳入；其他已有订阅桌面需用户确认后纳入。"
        case .api:
            summary = "检测到桌面 API 配置，不自动纳入订阅守护。"
        case .unknown:
            summary = "尚不能确认桌面配置范围；不将运行桌面视为已纳入。"
        }
        let cliScope = "CLI 仅核验/同步默认保存登录；未检测终端 shell 环境变量与各项目设置，不代表已运行 CLI 任务的状态，也不保护 CLI 进程。"
        guard let detail = controller.desktopScopeDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else { return summary + "\n" + cliScope }
        return summary + "\n" + cliScope + "\n" + detail
    }

    private var apiConfigurationTitle: String? {
        switch controller.apiConfiguration {
        case .subscription: return nil
        case .magpie: return "配置匹配 Magpie"
        case .ccSwitch: return "配置匹配 CC Switch"
        case .unknownAPI, .unconfirmed: return "API 配置来源未确认"
        case .conflict: return "API 配置来源有冲突"
        }
    }

    private var apiManagerActionTitle: String? {
        switch controller.apiConfiguration {
        case .magpie: return "打开 Magpie ↗"
        case .ccSwitch: return "打开 CC Switch ↗"
        case .subscription, .unknownAPI, .conflict, .unconfirmed: return nil
        }
    }

    private var apiConfigurationColor: Color {
        switch controller.apiConfiguration {
        case .unknownAPI, .conflict, .unconfirmed: return .warn
        case .subscription, .magpie, .ccSwitch: return .sub
        }
    }

    private var apiConfigurationHelp: String {
        "来源仅按已生效的配置标记匹配，不代表管理器当前正在代理或网关健康。\n退出 API 接管请在原工具中完成；此处只在来源已确认时打开原管理器，不修改模型、密钥或模式。来源未确认或有冲突时不提供打开入口。"
    }

    @ViewBuilder private var operationErrorFeedback: some View {
        if let message = controller.operationError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 10)).foregroundColor(.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { controller.clearOperationError() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.sub)
                .help("关闭操作错误")
                .accessibilityLabel("关闭操作错误")
            }
            .foregroundColor(.bad)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.bad.opacity(0.08)))
        }
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

    private var protectedDesktop: Bool {
        controller.desktopScope == .subscription && controller.desktopManaged &&
            controller.guardOnline && controller.lastDecision.allowed && store.claudeRunning
    }
    private var desktopPendingTakeover: Bool {
        controller.desktopScope == .subscription && controller.guardOnline && controller.lastDecision.allowed &&
            store.claudeRunning && !controller.desktopManaged
    }
    private var shouldOfferDesktopProtection: Bool {
        store.claudeRunning && controller.desktopScope == .subscription && controller.enabled &&
            controller.guardOnline && !controller.desktopManaged
    }
    private var statusColor: Color {
        if controller.working || !controller.enabled { return .sub }
        if !controller.guardOnline { return .warn }
        if controller.lastDecision.reason == .terminationFailed { return .bad }
        if controller.desktopScope != .subscription || desktopPendingTakeover { return .warn }
        if protectedDesktop { return .good }
        if !store.claudeRunning && controller.lastDecision.allowed { return .good }
        return .warn
    }
    private var statusTitle: String {
        if controller.working { return "正在更新设置" }
        if !controller.enabled { return "保护未启用" }
        if !controller.guardOnline { return "保护状态待确认" }
        if controller.lastDecision.reason == .terminationFailed { return "急停失败" }
        if controller.desktopScope == .api { return "当前桌面未纳入" }
        if controller.desktopScope == .unknown { return "桌面范围待确认" }
        if desktopPendingTakeover { return "当前桌面未保护" }
        if !controller.lastDecision.allowed { return "已拦截" }
        if !store.claudeRunning { return "守护已就绪" }
        if protectedDesktop { return "后台保护中" }
        return "保护状态待确认"
    }
    private var statusIcon: String {
        if controller.working { return "arrow.triangle.2.circlepath" }
        if !controller.enabled { return "shield" }
        if !controller.guardOnline { return "exclamationmark.triangle.fill" }
        if controller.desktopScope != .subscription || desktopPendingTakeover || !controller.lastDecision.allowed {
            return "shield.lefthalf.filled"
        }
        return protectedDesktop ? "checkmark.shield.fill" : "shield"
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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: statusIcon).font(.system(size: 12, weight: .semibold))
                                .frame(width: 16, height: 16)
                            Text(statusTitle).font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .foregroundColor(statusColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(desktopScopeShort)
                            .font(.system(size: 9.5, weight: .medium)).foregroundColor(desktopScopeColor)
                            .lineLimit(1).minimumScaleFactor(0.85)
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
                .help((showSettings ? "收起保护设置" : "配置代理、TUN 与出口国家") + "\n" + desktopScopeHelp)
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
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 12) {
                            Text("订阅桌面保护")
                                .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.txt)
                            Spacer()
                            Toggle("订阅桌面保护", isOn: protectionEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(busy || controller.working)
                        }
                        Text(desktopScopeSummary)
                            .font(.system(size: 9.5)).foregroundColor(desktopScopeColor)
                            .lineLimit(1).minimumScaleFactor(0.9)
                            .help(desktopScopeHelp)
                        if controller.activeCountry == nil {
                            Text("首次使用：设置目标国家和代理模式，再开启订阅桌面保护。")
                                .font(.system(size: 9.5)).foregroundColor(.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if shouldOfferDesktopProtection {
                        HStack(spacing: 8) {
                            Text("当前桌面尚未接管")
                                .font(.system(size: 9.5)).foregroundColor(.warn)
                            Spacer(minLength: 8)
                            Button("保护当前桌面") { confirmProtectCurrentDesktop = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.claude)
                                .disabled(busy || controller.working)
                                .opacity(busy || controller.working ? 0.55 : 1)
                        }
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("目标国家").font(.system(size: 10)).foregroundColor(.sub)
                                if controller.hasUnsavedChanges {
                                    Text("未保存").font(.system(size: 8.5, weight: .medium)).foregroundColor(.warn)
                                }
                            }
                            TextField("SG", text: $controller.country)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .multilineTextAlignment(.center).foregroundColor(.txt)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.bg))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stroke, lineWidth: 1))
                                .help("两位国家代码，例如 SG；草稿不会更改顶部已保存目标，保存后生效")
                                .disabled(busy || controller.working || controller.checking)
                        }
                        .frame(width: 78, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("代理模式").font(.system(size: 10)).foregroundColor(.sub)
                                Button { showProxyHelp.toggle() } label: {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 10)).foregroundColor(.sub)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(showProxyHelp ? "收起代理与 TUN 兼容说明" : "了解代理与 TUN 兼容")
                                .accessibilityLabel("代理与 TUN 兼容帮助")
                                .accessibilityHint(showProxyHelp ? "收起兼容说明" : "展开兼容说明")
                            }
                            Picker("代理模式", selection: $controller.mode) {
                                Text("Shadowrocket").tag(ProxyMode.shadowrocket)
                                Text("自动识别 TUN").tag(ProxyMode.auto)
                            }
                            .pickerStyle(.menu).labelsHidden()
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .disabled(busy || controller.working || controller.checking)
                            .help("当前输入为草稿；保存后生效，仅检查网络不会保存")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if controller.enabled {
                            Button(controller.hasUnsavedChanges ? "保存设置" : "已保存") {
                                Task { await controller.enable() }
                            }
                            .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 76, height: 28)
                            .foregroundColor(controller.hasUnsavedChanges ? .white : .sub)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(controller.hasUnsavedChanges ? Color.claude : Color.cardHi))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.stroke.opacity(controller.hasUnsavedChanges ? 0 : 1), lineWidth: 1))
                            .disabled(busy || controller.working || !controller.hasUnsavedChanges)
                            .opacity(busy || controller.working ? 0.55 : 1)
                            .help(controller.hasUnsavedChanges ? "保存当前输入并应用保护；顶部目标在保存后更新" : "国家与代理模式均已保存")
                        }
                    }
                    if showProxyHelp {
                        proxyHelpContent
                    }
                    HStack(spacing: 10) {
                        Button { Task { await controller.checkNow() } } label: {
                            HStack(spacing: 5) {
                                if controller.checking { ProgressView().controlSize(.small) }
                                Text(controller.checking ? "检查中…" : "仅检查网络")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .foregroundColor(.txt)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.cardHi))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.stroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain).disabled(busy || controller.working || controller.checking)
                        .opacity(busy || controller.working || controller.checking ? 0.55 : 1)
                        .help("仅按当前输入进行只读诊断；不保存、不启用保护、不打开 Claude。顶部目标始终为已保存配置")
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            Text("最近检测").foregroundColor(.sub)
                            Text(checkSummary)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(checkSummaryColor)
                            if let date = controller.lastCheckReport?.checkedAt {
                                Text("·").foregroundColor(.sub)
                                Text(date, style: .time)
                                    .font(.system(size: 9))
                                    .foregroundColor(.sub)
                            }
                        }
                        .font(.system(size: 9.5)).lineLimit(1)
                        .help(controller.lastCheckReport?.validationMessage ?? "最近结果来自只读检查，不代表已保存目标或后台保护状态")
                    }
                    operationErrorFeedback
                    HStack(spacing: 12) {
                        Button { showCheckDetails.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .rotationEffect(.degrees(showCheckDetails ? 90 : 0))
                                Text("检测详情")
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
                        .accessibilityLabel("检测详情")
                        .accessibilityValue(showCheckDetails ? "已展开" : "已收起")
                        Spacer(minLength: 8)
                    }
                    if showCheckDetails {
                        checkDetailsContent
                    }
                    DisclosureGroup("了解检查", isExpanded: $showCheckHelp) {
                        checkHelpContent
                    }
                    .font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
                    if let apiConfigurationTitle {
                        HStack(spacing: 6) {
                            Text("API 工具").foregroundColor(.sub)
                            Text(apiConfigurationTitle)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(apiConfigurationColor)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let apiManagerActionTitle {
                                Button(apiManagerActionTitle) {
                                    Task { await store.openAPIManager() }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.claude)
                                .disabled(busy || controller.working)
                                .opacity(busy || controller.working ? 0.55 : 1)
                                .help(apiConfigurationHelp)
                            }
                        }
                        .font(.system(size: 9.5))
                        .padding(.top, 2)
                        .help(apiConfigurationHelp)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
        .confirmationDialog("确认当前 Claude 桌面为订阅模式并纳入保护？网络异常时会关闭此桌面；不会切换账号或停止 CLI。API 模式请取消。",
                            isPresented: $confirmProtectCurrentDesktop) {
            Button("确认保护") {
                Task { await controller.protectCurrentDesktop() }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("停止后台保护？独立守卫将停用，切换器也不再放行打开或切换 Claude。仅退出界面不会停止保护。",
                            isPresented: $confirmStop) {
            Button("确认停止保护", role: .destructive) { controller.disable() }
            Button("取消", role: .cancel) {}
        }
    }
}
