import SwiftUI
import SwitcherCore

struct TerminalProtectionCard: View {
    @ObservedObject var store: Store
    @ObservedObject var controller: ProtectionController
    let busy: Bool
    @State private var confirmStop = false
    @State private var confirmProtectCurrentDesktop = false
    @State private var showSettings = false
    @State private var showCheckHelp = false
    @State private var showProxyHelp = false
    @State private var helpHover = false
    @State private var takeoverHover = false
    /// The report does not record the proxy mode, so remember the mode the check ran with; the picker
    /// is disabled while checking, so the value read on completion is the one that was used.
    @State private var checkedMode: ProxyMode?

    // MARK: Network check results

    private enum ItemStatus {
        case passed, failed, unknown, notRun, pending

        var color: Color {
            switch self {
            case .passed: return .good
            case .failed: return .bad
            case .unknown: return .warn
            case .notRun, .pending: return .sub
            }
        }
        var icon: String {
            switch self {
            case .passed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .unknown: return "questionmark.circle.fill"
            case .notRun: return "minus.circle"
            case .pending: return "ellipsis.circle"
            }
        }
        var spoken: String {
            switch self {
            case .passed: return "通过"
            case .failed: return "未通过"
            case .unknown: return "未知，不放行"
            case .notRun: return "未检查"
            case .pending: return "本轮结果未出"
            }
        }
    }

    private struct NetworkItem {
        let title: String
        let value: String
        let status: ItemStatus
        var help: String?
    }

    private var networkItems: [NetworkItem] {
        // While re-checking, never show the previous round's results as if they were this round's.
        if controller.checking {
            return ["代理", "TUN", "出口国家"].map { NetworkItem(title: $0, value: "检查中…", status: .pending) }
        }
        let observation = controller.lastCheckReport?.observation
        let proxy: NetworkItem
        if let observation {
            if checkedMode == .auto {
                // Auto mode has no separate proxy probe; it is the TUN result, so don't count it twice.
                proxy = NetworkItem(title: "代理", value: "随 TUN 判定", status: .notRun,
                                    help: "自动模式不单独检查代理，以 TUN 结果为准。")
            } else {
                proxy = NetworkItem(title: "代理", value: observation.proxyConnected ? "已连接" : "未连接",
                                    status: observation.proxyConnected ? .passed : .failed)
            }
        } else {
            proxy = NetworkItem(title: "代理", value: "未检查", status: .notRun)
        }
        let tun = observation.map {
            NetworkItem(title: "TUN", value: $0.tunOnline ? "在线" : "未检测到", status: $0.tunOnline ? .passed : .failed,
                        help: "仅识别 198.18.* TUN 地址。")
        } ?? NetworkItem(title: "TUN", value: "未检查", status: .notRun)
        return [proxy, tun, countryItem]
    }

    private var countryItem: NetworkItem {
        guard let report = controller.lastCheckReport, let observation = report.observation else {
            return NetworkItem(title: "出口国家", value: "未检查", status: .notRun)
        }
        if observation.routesDisagree {
            return NetworkItem(title: "出口国家", value: "各域名不一致", status: .failed,
                               help: "Claude 各域名的出口国家不同，不放行。")
        }
        guard let country = observation.country, !country.isEmpty else {
            // A missing country can't tell whether the request was skipped or ran and was then discarded,
            // so it is "unconfirmed", never "not run".
            let help = observation.proxyConnected && observation.tunOnline
                ? "无法确认出口国家，按未通过处理。"
                : "代理或 TUN 未通过，本次没有可用的出口国家结果；按未通过处理。"
            return NetworkItem(title: "出口国家", value: "未确认", status: .unknown, help: help)
        }
        guard let target = report.targetCountry else {
            return NetworkItem(title: "出口国家", value: country, status: .unknown)
        }
        let matches = country.uppercased() == target.uppercased()
        return NetworkItem(title: "出口国家", value: matches ? country : "\(country) ≠ \(target)",
                           status: matches ? .passed : .failed)
    }

    private func failureText(_ decision: SafetyDecision) -> String {
        switch decision.reason {
        case .proxyDisconnected: return "未通过：代理未连接"
        case .tunMissing: return "未通过：未检测到 TUN"
        case .routesDisagree: return "未通过：各域名出口不一致"
        case .countryUnknown: return "未通过：无法确认出口国家"
        case .countryMismatch:
            return "未通过：出口 \(decision.observedCountry ?? "未知")，目标 \(decision.expectedCountry ?? "未知")"
        default: return "未通过：" + decision.message
        }
    }

    private var verdict: (text: String, color: Color, icon: String) {
        guard let report = controller.lastCheckReport else { return ("尚未检查", .sub, "minus.circle") }
        if let message = report.validationMessage { return ("输入无效：" + message, .warn, "exclamationmark.triangle.fill") }
        guard report.observation != nil else { return ("检查未完成", .sub, "questionmark.circle") }
        if report.passed { return ("网络通过 · 目标 \(report.targetCountry ?? "")", .good, "checkmark.circle.fill") }
        return (failureText(report.decision), .bad, "xmark.circle.fill")
    }

    /// One line of context only when the result could be misread against the current inputs.
    private var reportContextNote: String? {
        guard let report = controller.lastCheckReport, report.validationMessage == nil,
              let target = report.targetCountry else { return nil }
        let draft = controller.country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if draft != target || (checkedMode != nil && checkedMode != controller.mode) {
            return "输入已修改；以上是上次输入的结果，请重新检查。"
        }
        if controller.hasUnsavedChanges { return "按未保存的输入检查；保存前顶部目标不变。" }
        return nil
    }

    private func networkCell(_ item: NetworkItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
            HStack(spacing: 4) {
                Image(systemName: item.status.icon).font(.system(size: 10))
                Text(item.value).font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundColor(item.status.color)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.card))
        .help(item.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title)：\(item.value)，\(item.status.spoken)")
    }

    /// Shown in place as soon as a check runs: verdict, the three real results, then one footnote.
    @ViewBuilder private var checkResults: some View {
        if controller.checking || controller.lastCheckReport != nil {
            let result = verdict
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if controller.checking {
                        ProgressView().controlSize(.small)
                        Text("正在检查代理、TUN 和出口国家…").foregroundColor(.sub)
                    } else {
                        Image(systemName: result.icon)
                        Text(result.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    if !controller.checking, let date = controller.lastCheckReport?.checkedAt {
                        Text(date, style: .time).font(.system(size: 9.5)).foregroundColor(.sub)
                    }
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(controller.checking ? .sub : result.color)
                .accessibilityElement(children: .combine)
                if controller.checking || controller.lastCheckReport?.validationMessage == nil {
                    HStack(spacing: 6) {
                        ForEach(networkItems, id: \.title) { networkCell($0) }
                    }
                }
                if let note = reportContextNote, !controller.checking {
                    Text(note).font(.system(size: 9.5)).foregroundColor(.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("仅诊断，不改变设置与保护状态。")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Link("IP / WebRTC ↗", destination: URL(string: "https://ip.net.coffee/claude/")!)
                        .foregroundColor(.claude)
                        .help("第三方网页体检，结果仅供参考，不作为打开 Claude 的门禁")
                        .accessibilityLabel("第三方 IP 与 WebRTC 体检，仅供参考")
                }
                .font(.system(size: 9.5)).foregroundColor(.sub)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.bg.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke((controller.checking ? Color.stroke : result.color).opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Help

    private var checkHelpContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            helpRow("仅检查网络", "按当前输入只读诊断；不保存、不启用保护、不打开 Claude。")
            helpRow("检查并打开", "按已保存配置复查，门禁通过才打开当前账号。")
            helpRow("纳入保护", "把已在运行的订阅桌面纳入守卫，需确认一次。")
            Divider().opacity(0.6)
            Text("后台守卫约每 \(Int(SafetyConfig.interval)) 秒复查一次，非实时；失败或未知均不放行。")
            // The current desktop's scope detail lives on the scope line's hover help; not repeated here.
            Text("只保护订阅桌面；API 桌面不纳入，CLI 只核验默认登录、不保护 CLI 进程。")
        }
        .font(.system(size: 10.5)).foregroundColor(.sub)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(12)
    }

    private func helpRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.txt)
            Text(detail)
        }
    }

    // MARK: Scope

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
        case .subscription: summary = "本入口启动的订阅桌面自动纳入；其他已运行的订阅桌面需确认一次。"
        case .api: summary = "检测到桌面 API 配置，不纳入订阅守护。"
        case .unknown: summary = "尚不能确认桌面配置，不将运行中的桌面视为已纳入。"
        }
        guard let detail = controller.desktopScopeDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else { return summary }
        return summary + "\n" + detail
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

    // MARK: Notices

    /// A failed save/enable/takeover is history, not the live state: say so and let the user dismiss it.
    /// Nothing here clears it automatically, a passing network check included.
    @ViewBuilder private var operationErrorFeedback: some View {
        if let message = controller.operationError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundColor(.bad)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("上次操作未完成")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.bad)
                    Text(message)
                        .font(.system(size: 10)).foregroundColor(.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button { controller.clearOperationError() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.sub)
                .help("关闭提示；当前状态以上方为准，关闭不改变保护")
                .accessibilityLabel("关闭上次操作提示")
            }
            .padding(.leading, 10).padding(.trailing, 2).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.bad.opacity(0.08)))
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }

    /// Visible next to "当前桌面未保护" without opening settings. Only for a running subscription desktop
    /// while the guard is online and the network currently passes; the confirmation dialog still decides.
    @ViewBuilder private var desktopTakeoverOffer: some View {
        if offerDesktopProtection {
            Rectangle().fill(Color.stroke.opacity(0.4)).frame(height: 1)
            HStack(spacing: 10) {
                Text("当前桌面未纳入保护")
                    .font(.system(size: 10.5, weight: .medium)).foregroundColor(.txt)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { confirmProtectCurrentDesktop = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield").font(.system(size: 10, weight: .semibold))
                        Text("纳入保护").font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 10).frame(height: 28)
                    .foregroundColor(.claude)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.claude.opacity(takeoverHover ? 0.26 : 0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.claude.opacity(0.24), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy || controller.working)
                .opacity(busy || controller.working ? 0.55 : 1)
                .onHover { takeoverHover = $0 }
                .help("需先确认")
                .accessibilityHint("会先弹出确认")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    // MARK: State

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
    private var offerDesktopProtection: Bool {
        desktopPendingTakeover && controller.enabled && !controller.working
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
        case .auto: return "自动模式仅识别 198.18.* TUN 地址，不单独检查代理，也不修改系统代理。"
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                TerminalStrip(store: store)
                // Full-height divider between the terminal strip and the protection column.
                Rectangle().fill(Color.stroke.opacity(0.55)).frame(width: 1).padding(.vertical, 10)
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
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help((showSettings ? "收起保护设置" : "保护设置与网络检查") + "\n" + desktopScopeHelp)
                .accessibilityLabel("保护：\(statusTitle)，\(desktopScopeShort)，目标 \(controller.activeCountry ?? "未设置")")
                .accessibilityHint(showSettings ? "收起保护设置" : "展开保护设置与网络检查")
            }
            .fixedSize(horizontal: false, vertical: true)

            operationErrorFeedback
            desktopTakeoverOffer

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
                settings
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
        .onChange(of: controller.lastCheckReport?.checkedAt) { _ in checkedMode = controller.mode }
        .confirmationDialog("将当前桌面纳入保护？", isPresented: $confirmProtectCurrentDesktop,
                            titleVisibility: .visible) {
            Button("纳入保护") {
                // Re-validate at confirm time; the desktop, network or guard may have changed meanwhile.
                guard offerDesktopProtection, !busy else { return }
                Task { await controller.protectCurrentDesktop() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅限订阅桌面（非 API）。纳入后若网络不符，守卫可能关闭此桌面；不会切换账号，也不会停止 CLI。")
        }
        .confirmationDialog("停止后台保护？独立守卫将停用，切换器也不再放行打开或切换 Claude。仅退出界面不会停止保护。",
                            isPresented: $confirmStop) {
            Button("确认停止保护", role: .destructive) { controller.disable() }
            Button("取消", role: .cancel) {}
        }
    }

    private var settings: some View {
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
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("目标国家").font(.system(size: 10)).foregroundColor(.sub)
                        if controller.hasUnsavedChanges {
                            Text("未保存").font(.system(size: 8.5, weight: .medium)).foregroundColor(.warn)
                        }
                    }
                    .frame(height: 22)
                    TextField("SG", text: $controller.country)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center).foregroundColor(.txt)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.bg))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stroke, lineWidth: 1))
                        .help("两位国家代码，例如 SG；保存后顶部目标才更新")
                        .accessibilityLabel("目标国家")
                        .disabled(busy || controller.working || controller.checking)
                }
                .frame(width: 78, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        Text("代理模式").font(.system(size: 10)).foregroundColor(.sub)
                        Button { showProxyHelp.toggle() } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 10)).foregroundColor(.sub)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("代理与 TUN 兼容说明")
                        .accessibilityLabel("代理与 TUN 兼容说明")
                        .popover(isPresented: $showProxyHelp, arrowEdge: .bottom) {
                            Text(modeDetail)
                                .font(.system(size: 10.5)).foregroundColor(.txt)
                                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                .frame(width: 240, alignment: .leading).padding(12)
                        }
                    }
                    .frame(height: 22)
                    Picker("代理模式", selection: $controller.mode) {
                        Text("Shadowrocket").tag(ProxyMode.shadowrocket)
                        Text("自动识别 TUN").tag(ProxyMode.auto)
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .disabled(busy || controller.working || controller.checking)
                    .help("保存后生效；仅检查网络不会保存")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if controller.enabled {
                    Button { Task { await controller.enable() } } label: {
                        Text(controller.hasUnsavedChanges ? "保存设置" : "已保存")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 76, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            HStack(spacing: 8) {
                Button { Task { await controller.checkNow() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network").font(.system(size: 10, weight: .semibold))
                        Text(controller.checking ? "检查中…" : "仅检查网络")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .foregroundColor(.txt)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.cardHi))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.stroke, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(busy || controller.working || controller.checking)
                .opacity(busy || controller.working || controller.checking ? 0.55 : 1)
                .help("按当前输入只读诊断；不保存、不启用保护、不打开 Claude")
                .accessibilityHint("只读诊断，不保存、不启用保护、不打开 Claude")
                if controller.lastCheckReport == nil && !controller.checking {
                    Text("只读，不保存")
                        .font(.system(size: 9.5)).foregroundColor(.sub).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { showCheckHelp.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle").font(.system(size: 10.5))
                        Text("检查说明").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(helpHover || showCheckHelp ? .txt : .sub)
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color.stroke.opacity(helpHover || showCheckHelp ? 0.6 : 0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { helpHover = $0 }
                .help("三种动作的区别、后台间隔与保护范围")
                .accessibilityLabel("检查说明")
                .popover(isPresented: $showCheckHelp, arrowEdge: .bottom) { checkHelpContent }
            }
            checkResults
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
