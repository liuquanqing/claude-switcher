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
    @State private var settingsHover = false
    /// The report does not record the proxy mode, so remember the mode the check ran with; the picker
    /// is disabled while checking, so the value read on completion is the one that was used.
    @State private var checkedMode: ProxyMode?
    /// The result block folds on its own, independent of the settings section. Every finished round
    /// (pass, fail or invalid input) re-expands it; after that only the user folds it.
    @State private var resultsExpanded = true
    @State private var resultsHover = false
    /// Shared by the open column and the panel beneath it, so the two read as one region.
    private let panelTint = Color.white.opacity(0.03)

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

    /// The inputs changed after the last round, so its result no longer describes them.
    private var resultStale: Bool {
        guard let report = controller.lastCheckReport, report.validationMessage == nil,
              let target = report.targetCountry else { return false }
        let draft = controller.country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return draft != target || (checkedMode != nil && checkedMode != controller.mode)
    }

    /// The headline used both expanded and folded. A stale pass must never read as a fresh one,
    /// so a stale result loses its verdict colour and icon in either state.
    private var displayVerdict: (text: String, color: Color, icon: String) {
        if resultStale { return ("输入已修改，请重新检查", .warn, "arrow.triangle.2.circlepath") }
        return verdict
    }

    /// One line of context only when the result could be misread against the current inputs.
    private var reportContextNote: String? {
        guard let report = controller.lastCheckReport, report.validationMessage == nil,
              let target = report.targetCountry else { return nil }
        if resultStale { return "以下是上次输入（目标 \(target)）的结果，不代表当前输入。" }
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

    /// The verdict row doubles as the fold toggle: the whole row is the hit area, and folded it is the
    /// one-line summary (verdict + time). While checking it never shows the previous round's verdict.
    private var resultHeaderRow: some View {
        let result = displayVerdict
        let checking = controller.checking
        return Button { resultsExpanded.toggle() } label: {
            HStack(spacing: 6) {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("正在检查代理、TUN 和出口国家…").foregroundColor(.sub).lineLimit(1)
                } else {
                    Image(systemName: result.icon)
                    Text(result.text)
                        .lineLimit(resultsExpanded ? 2 : 1).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if !checking, let date = controller.lastCheckReport?.checkedAt {
                    Text(date, style: .time).font(.system(size: 9.5, weight: .regular)).foregroundColor(.sub)
                }
                Image(systemName: resultsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundColor(resultsHover ? .txt : .sub)
                    .frame(width: 12)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(checking ? .sub : result.color)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { resultsHover = $0 }
        .help(resultsExpanded ? "收起检查结果" : "展开检查结果")
        .accessibilityLabel(checking ? "网络检查进行中" : "网络检查：\(result.text)")
        .accessibilityHint(resultsExpanded ? "收起检查结果" : "展开检查结果")
    }

    /// Shown in place as soon as a check runs. Expanded: verdict, the three real results, one footnote.
    /// Folded: just the verdict row, so the result stays visible without its detail.
    @ViewBuilder private var checkResults: some View {
        if controller.checking || controller.lastCheckReport != nil {
            let borderColor = controller.checking ? Color.stroke : displayVerdict.color
            VStack(alignment: .leading, spacing: 0) {
                resultHeaderRow
                if resultsExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if controller.checking || controller.lastCheckReport?.validationMessage == nil {
                            HStack(spacing: 6) {
                                ForEach(networkItems, id: \.title) { networkCell($0) }
                            }
                            // Previous inputs' cells stay readable but visibly not current.
                            .opacity(resultStale && !controller.checking ? 0.45 : 1)
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
                    .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
                }
            }
            .padding(.top, 2).padding(.bottom, resultsExpanded ? 0 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.bg.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Help

    private var checkHelpContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            helpRow("仅检查网络", "按当前输入只读诊断；不保存、不启用保护、不打开 Claude。")
            helpRow("顶部 打开 / 显示", "按已保存配置复查门禁；未运行则打开当前账号，已纳入保护的桌面切到前台。")
            helpRow("桌面未纳入（可点击）", "守卫服务在线但未接管当前订阅桌面；点该标签确认一次后才纳入，右侧箭头仅展开设置。")
            Divider().opacity(0.6)
            Text("后台守卫约每 \(Int(SafetyConfig.interval)) 秒复查一次，非实时；失败或未知均不放行。")
            // The current desktop's scope detail lives on the column / switch hover help; not repeated here.
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

    /// The scope is spelled out only on demand (column hover, switch hover, check help), never as a
    /// standing line: the column title already names the desktop where it matters.
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

    // MARK: Notices

    /// The live problem behind an exception title (guard offline / blocked), with its next step.
    /// API / unknown scope already say everything in the column, so their generic message is skipped.
    private var issueText: String? {
        guard controller.enabled, !controller.working else { return nil }
        guard !controller.guardOnline || !controller.lastDecision.allowed else { return nil }
        if controller.guardOnline, controller.desktopScope != .subscription,
           controller.lastDecision.reason == .unsupportedMode { return nil }
        return controller.status
    }

    /// Problems first, then a dismissible failed-operation note. Placed under the header when folded and
    /// at the top of the settings panel when open, so the panel stays attached to the column above it.
    @ViewBuilder private var notices: some View {
        if let issueText {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).padding(.top, 1)
                Text(issueText).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10)).foregroundColor(statusColor)
            .help(issueText)
            .accessibilityElement(children: .combine)
        }
        operationErrorFeedback
    }

    private var hasNotices: Bool { issueText != nil || controller.operationError != nil }

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
        }
    }

    /// While the desktop can be taken over, the state and the action are one control: the tinted
    /// "桌面未纳入" pill states the fact and, when clicked, only opens the confirmation dialog (that
    /// meaning lives in help/accessibilityHint; the second line shows only the saved target). The
    /// settings fold is a separate chevron button beside it (siblings in an HStack, never nested or
    /// overlaid), so the two hit areas cannot intercept each other. Only used while
    /// `offerDesktopProtection` holds.
    private var offerHeader: some View {
        let disabled = busy || controller.working
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button { confirmProtectCurrentDesktop = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: statusIcon).font(.system(size: 11, weight: .semibold))
                            .frame(width: 14, height: 14)
                        Text(statusTitle).font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 2)
                        Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(statusColor.opacity(disabled ? 0.06 : (takeoverHover ? 0.24 : 0.15))))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(statusColor.opacity(0.35), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
                .onHover { takeoverHover = $0 }
                .help("守卫服务已在线，但这个桌面还没交给守卫；点击后先确认，不会开启或关闭服务")
                .accessibilityLabel("桌面未纳入保护，目标 \(controller.activeCountry ?? "未设置")")
                .accessibilityHint("纳入当前桌面；会先弹出确认，取消不做任何改动")
                settingsToggleButton
            }
            Text("目标 \(controller.activeCountry ?? "未设置")")
                .font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
                .lineLimit(1).fixedSize()
                .padding(.leading, 7)
        }
        .padding(.horizontal, 2).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Chevron-only settings disclosure used beside the merged pill.
    private var settingsToggleButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(showSettings ? 180 : 0))
                .foregroundColor(settingsHover || showSettings ? .txt : .sub)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(settingsHover && !showSettings ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { settingsHover = $0 }
        .help((showSettings ? "收起保护设置" : "展开保护设置") + "\n" + desktopScopeHelp)
        .accessibilityLabel(showSettings ? "收起保护设置" : "展开保护设置")
        .accessibilityHint("开关、目标国家、代理模式与网络检查")
    }

    /// The column header: what the guard means for the desktop right now (line 1) and the one fact or
    /// next step that matters in that state (line 2). The whole block is the settings disclosure; its
    /// only open/close affordance is the chevron beside the title, and the open panel visually extends
    /// from this column, so entry and fold belong to the same place.
    private var statusButton: some View {
        Button { showSettings.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: statusIcon).font(.system(size: 11, weight: .semibold))
                        .frame(width: 14, height: 14)
                    Text(statusTitle).font(.system(size: 11, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(showSettings ? 180 : 0))
                        .foregroundColor(settingsHover || showSettings ? .txt : .sub)
                        .frame(width: 12)
                }
                .frame(height: 22)
                .foregroundColor(statusColor)
                // Sized to fit the 164pt column; nothing here is allowed to end in "…".
                Text(statusDetail)
                    .font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
                    .lineLimit(1).fixedSize()
                    .padding(.leading, 20)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(settingsHover && !showSettings ? 0.045 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { settingsHover = $0 }
        .help((showSettings ? "收起保护设置" : "展开保护设置") + "\n" + desktopScopeHelp)
        .accessibilityLabel("保护：\(statusTitle)，\(statusDetail)")
        .accessibilityHint(showSettings ? "收起保护设置" : "展开保护设置：开关、目标国家、代理模式与网络检查")
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
        // API is a normal mode the guard simply doesn't cover; only an unknown desktop is a warning.
        if controller.desktopScope == .api { return .sub }
        if controller.desktopScope == .unknown || desktopPendingTakeover { return .warn }
        if protectedDesktop { return .good }
        if !store.claudeRunning && controller.lastDecision.allowed { return .good }
        return .warn
    }
    /// Titles describe the guard against the desktop only. "Protected" always names the desktop, so it
    /// can't be read as covering the terminal strip beside it or the account as a whole.
    private var statusTitle: String {
        if controller.working { return "正在更新设置" }
        if !controller.enabled { return "保护未启用" }
        if !controller.guardOnline { return "保护状态待确认" }
        if controller.lastDecision.reason == .terminationFailed { return "急停失败" }
        if controller.desktopScope == .api { return "守护不适用" }
        if controller.desktopScope == .unknown { return "桌面范围待确认" }
        if desktopPendingTakeover { return "桌面未纳入" }
        if !controller.lastDecision.allowed { return "已拦截" }
        if !store.claudeRunning { return "守护已就绪" }
        if protectedDesktop { return "桌面保护中" }
        return "保护状态待确认"
    }
    /// The one useful fact per state. The target shown is always the saved one the guard runs with,
    /// never the draft in the settings field.
    private var statusDetail: String {
        let target = "目标 \(controller.activeCountry ?? "未设置")"
        if controller.working { return target }
        if !controller.enabled { return showSettings ? "在下方打开开关" : "点此设置并开启" }
        if !controller.guardOnline || controller.lastDecision.reason == .terminationFailed { return target }
        switch controller.desktopScope {
        case .api:
            switch controller.apiConfiguration {
            case .magpie: return "API · 来源 Magpie"
            case .ccSwitch: return "API · 来源 CC Switch"
            case .conflict: return "API · 来源有冲突"
            case .subscription, .unknownAPI, .unconfirmed: return "API · 来源未确认"
            }
        case .unknown: return "确认前不算受保护"
        case .subscription: break
        }
        // Guard-online is implied by reaching here; when takeover is offered, `offerHeader` shows
        // its own target line instead of this one.
        if !controller.lastDecision.allowed { return target }
        if !store.claudeRunning { return target + " · 桌面未运行" }
        return target
    }
    private var statusIcon: String {
        if controller.working { return "arrow.triangle.2.circlepath" }
        if !controller.enabled { return "shield" }
        if !controller.guardOnline { return "exclamationmark.triangle.fill" }
        if controller.desktopScope == .api { return "shield" }
        if controller.desktopScope == .unknown || desktopPendingTakeover || !controller.lastDecision.allowed {
            return "shield.lefthalf.filled"
        }
        return protectedDesktop ? "checkmark.shield.fill" : "shield"
    }
    private func modeName(_ mode: ProxyMode?) -> String {
        switch mode {
        case .shadowrocket: return "Shadowrocket"
        case .auto: return "自动识别 TUN"
        case nil: return "未设置"
        }
    }
    /// Shown only while the form differs from the saved config. States the saved values only;
    /// whether the guard is actually running is shown by the status block, not here.
    private var unsavedNote: String? {
        guard controller.enabled, controller.hasUnsavedChanges else { return nil }
        guard let active = controller.activeCountry else { return "未保存 · 尚无已保存设置" }
        return "未保存 · 已保存为 \(active) · \(modeName(controller.activeProxyMode))"
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
                    // Open: the line closes off the terminal side only, so the tinted column runs
                    // straight into the panel below it like a tab.
                    .overlay(alignment: .bottom) {
                        if showSettings { Rectangle().fill(Color.stroke.opacity(0.4)).frame(height: 1) }
                    }
                Rectangle().fill(Color.stroke.opacity(0.55)).frame(width: 1)
                    .padding(.vertical, showSettings ? 0 : 10)
                // Offered: one merged state+action pill plus a separate fold chevron (siblings).
                // Otherwise the whole status block is the settings disclosure.
                VStack(alignment: .leading, spacing: 0) {
                    if offerDesktopProtection {
                        offerHeader
                    } else {
                        statusButton
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).padding(.vertical, 4)
                .frame(width: 164)
                .frame(maxHeight: .infinity)
                .background(showSettings ? panelTint : Color.clear)
            }
            .fixedSize(horizontal: false, vertical: true)

            if showSettings {
                settings.background(panelTint)
            } else if hasNotices {
                Rectangle().fill(Color.stroke.opacity(0.4)).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) { notices }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: controller.lastCheckReport?.checkedAt) { _ in
            checkedMode = controller.mode
            resultsExpanded = true
        }
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
        // Controls only: status, scope and target are the column's job and are not repeated here.
        VStack(alignment: .leading, spacing: 10) {
            if hasNotices {
                VStack(alignment: .leading, spacing: 8) { notices }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("后台保护")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.txt)
                    if !controller.enabled {
                        Text("填好目标国家和代理模式，再打开右侧开关。")
                            .font(.system(size: 9.5)).foregroundColor(.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle("后台保护", isOn: protectionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(busy || controller.working)
                    .help("开启后按下方设置保存并启动守卫；关闭前会先确认。\n" + desktopScopeHelp
                          + "\n终端只核验默认保存的登录，不停止运行中的 CLI。")
            }
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("目标国家").font(.system(size: 10)).foregroundColor(.sub)
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
            if let unsavedNote {
                Text(unsavedNote)
                    .font(.system(size: 9.5)).foregroundColor(.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -4)
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
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
