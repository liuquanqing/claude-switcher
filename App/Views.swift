import AppKit
import SwiftUI
import SwitcherCore

// MARK: - Colors

extension Color {
    init(hex: UInt32, _ a: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: a)
    }
    static let bg = Color(hex: 0x1C1B19)
    static let card = Color(hex: 0x262522)
    static let cardHi = Color(hex: 0x2D2A26)
    static let stroke = Color(hex: 0x3A3833)
    static let txt = Color(hex: 0xF2EFE8)
    static let sub = Color(hex: 0xA39D92)
    static let claude = Color(hex: 0xD97757)
    static let good = Color(hex: 0x6CC57C)
    static let warn = Color(hex: 0xE5B454)
    static let bad = Color(hex: 0xE5675A)
}

func levelColor(_ left: Double?) -> Color {
    guard let l = left else { return .sub }
    return l > 50 ? .good : l > 20 ? .warn : .bad
}

// MARK: - Formatting

func left(_ w: Window?) -> Double? { w.map { max(0, 100 - $0.used) } }
func pct(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "--" }

func countdown(_ d: Date?) -> String {
    guard let d else { return "重置时间未知" }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "已到重置时间" }
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 { return "\(h) 小时 \(m) 分后重置" }
    if m > 0 { return "\(m) 分钟后重置" }
    return "1 分钟内重置"
}

func weekdayTime(_ d: Date?) -> String {
    guard let d else { return "--" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "E HH:mm"
    return f.string(from: d)
}

func ago(_ d: Date?) -> String {
    guard let d else { return "尚未更新" }
    let s = max(0, Int(-d.timeIntervalSinceNow))
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return "\(s / 86400) 天前"
}

/// Identity line for a profile. Loading wording only appears while a request is really running;
/// otherwise a missing identity is just "no account info".
func accountLine(_ p: Profile?) -> String? {
    guard let p else { return nil }
    if !p.signedIn { return "尚未登录" }
    if let email = p.snapshot?.email { return email }
    return p.usageState == .loading ? "正在读取账号信息…" : "暂无账号信息"
}

// MARK: - Views

struct Pill: View {
    let text: String; let fg: Color; let bg: Color
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundColor(fg).background(RoundedRectangle(cornerRadius: 6).fill(bg))
    }
}

struct Bar: View {
    let value: Double?; let color: Color; var height: CGFloat = 4
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.stroke.opacity(0.72))
                Capsule().fill(color)
                    .frame(width: g.size.width * CGFloat(min(max((value ?? 0) / 100, 0), 1)))
            }
        }.frame(height: height)
    }
}

struct Header: View {
    @ObservedObject var store: Store
    @ObservedObject var protection: ProtectionController
    let openClaude: () -> Void
    @State private var openHover = false
    @State private var showAbout = false

    private var appIcon: NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.png") else { return nil }
        return NSImage(contentsOf: url)
    }

    private var versionText: String? {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case (let s?, let b?) where s != b: return "版本 \(s)（\(b)）"
        case (let s?, _): return "版本 \(s)"
        case (nil, let b?): return "版本 \(b)"
        default: return nil
        }
    }

    // MARK: Desktop control
    //
    // One control carries both the process state and the action. The action always goes through
    // `openClaude` (Store.openProtectedClaude → network gate first); "显示" is only a label for the
    // running case, never a shortcut around the gate or around the takeover confirmation.

    private var running: Bool { store.claudeRunning }
    private var controlLocked: Bool { store.busy != nil || protection.working }

    private var actionTitle: String { running ? "显示" : "打开" }
    private var actionIcon: String { running ? "macwindow" : "play.fill" }

    private var desktopHelp: String {
        var lines: [String]
        if !running {
            lines = ["先检查网络门禁，通过后打开 \(store.current)。"]
        } else if protection.desktopScope == .subscription && !protection.desktopManaged {
            lines = ["先检查网络门禁；当前桌面尚未纳入保护，会提示先在保护卡片中确认纳入，不会自动接管或关闭。"]
        } else {
            lines = ["先检查网络门禁，通过后把已纳入保护的桌面切到前台。"]
        }
        if protection.desktopScope != .subscription { lines.append("当前桌面不是已确认的订阅配置，门禁会拦下。") }
        lines.append((store.isDemo ? "演示状态。" : "") + "“运行中”只表示进程存在，不代表已登录、网络可用或已保护。")
        return lines.joined(separator: "\n")
    }

    private var desktopControl: some View {
        Button(action: openClaude) {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(running ? Color.good : Color.sub.opacity(0.7)).frame(width: 6, height: 6)
                    Text(running ? "桌面运行中" : "桌面未运行")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(running ? .txt : .sub)
                        .lineLimit(1).fixedSize()
                }
                .padding(.leading, 10).padding(.trailing, 9)
                Rectangle().fill(Color.claude.opacity(0.28)).frame(width: 1, height: 16)
                HStack(spacing: 5) {
                    Image(systemName: actionIcon).font(.system(size: running ? 9.5 : 8, weight: .bold))
                    Text(actionTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .foregroundColor(.claude)
                .padding(.leading, 9).padding(.trailing, 11)
            }
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.claude.opacity(openHover ? 0.2 : 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.claude.opacity(0.26), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(controlLocked)
        .opacity(controlLocked ? 0.45 : 1)
        .help(desktopHelp)
        .onHover { openHover = $0 }
        .accessibilityLabel("Claude 桌面\(running ? "运行中" : "未运行")，\(actionTitle)")
        .accessibilityHint(desktopHelp)
    }

    // MARK: Body

    private var iconView: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Color.claude.opacity(0.13))
                    RoundedRectangle(cornerRadius: 11).stroke(Color.claude.opacity(0.35), lineWidth: 1)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 19, weight: .semibold)).foregroundColor(.claude)
                }
            }
        }
        .frame(width: 38, height: 38)
    }

    var body: some View {
        let a = store.active, s = a?.snapshot
        HStack(spacing: 12) {
            // The product name lives on the icon (hover / click), so the account is the only title.
            Button { showAbout.toggle() } label: { iconView.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Claude Switcher" + (versionText.map { " · \($0)" } ?? ""))
                .accessibilityLabel("关于 Claude Switcher")
                .popover(isPresented: $showAbout, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude Switcher").font(.system(size: 12, weight: .semibold)).foregroundColor(.txt)
                        if let versionText {
                            Text(versionText).font(.system(size: 10, design: .monospaced)).foregroundColor(.sub)
                        }
                        Text("多账号切换与订阅桌面保护").font(.system(size: 10.5)).foregroundColor(.sub)
                    }
                    .frame(width: 200, alignment: .leading).padding(12)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(store.current).font(.system(size: 19, weight: .bold)).foregroundColor(.txt).lineLimit(1)
                    Text("当前账号").font(.system(size: 9.5, weight: .medium)).foregroundColor(.claude.opacity(0.85))
                        .fixedSize()
                }
                Text([accountLine(a), s?.plan]
                    .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10.5)).foregroundColor(.sub).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            desktopControl
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
    }
}

@MainActor
struct TerminalStrip: View {
    @ObservedObject var store: Store
    @ObservedObject private var protection: ProtectionController
    @State private var hover = false
    @State private var showHelp = false
    @State private var confirmSync = false
    /// Account name pinned when the dialog opens, so a background refresh or external switch
    /// can't make the user confirm X and sync Y.
    @State private var syncTarget = ""
    @State private var syncStale = false

    init(store: Store) {
        self.store = store
        self.protection = store.protection
    }

    private var controlsLocked: Bool { store.busy != nil || store.refreshing }

    /// A background check is in flight. The strip keeps showing the last finished result; only the
    /// info popover mentions the check, so periodic refreshes never reshape the card.
    private var checking: Bool { store.cliStatusRefreshing }

    private static let checkedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    /// When the last full check finished. Says nothing about whether it succeeded.
    private var checkedLine: String {
        guard let date = store.cliStatusCheckedAt else {
            return checking ? "首次检查进行中，完成后更新。" : "尚未完成过检查。"
        }
        let when = "最近一次检查完成于 \(Self.checkedFormatter.string(from: date))，以上为该次结论，不是实时状态。"
        return checking ? when + "\n新的检查进行中，完成后更新。" : when
    }

    /// Sync is only offered after a check found a difference, and only against a subscription
    /// desktop; API / unknown desktops have no subscription account to sync to.
    private var canSync: Bool { store.cliStatus == .different && protection.desktopScope == .subscription }

    private var checkHelp: String {
        switch protection.desktopScope {
        case .subscription: return "只读检查默认保存的 CLI 登录并与当前桌面比较；不会修改登录，也不检测已运行的 CLI 任务"
        case .api, .unknown: return "只读检查默认保存的 CLI 订阅登录；当前桌面无订阅账号可比较，不会修改登录"
        }
    }

    /// Green needs a real comparison against a subscription desktop. A `matched` seen under another
    /// scope is stale (the backend invalidates on scope change) and is never shown as a match.
    private var matched: Bool { store.cliStatus == .matched && protection.desktopScope == .subscription }

    /// Identity verified remotely, but an API / unknown desktop left nothing to compare. Taken only
    /// from the backend flag, never from email, cache or detail text, and never treated as a match.
    private var standaloneVerified: Bool {
        store.cliStatus == .unverified && store.cliStandaloneVerified && protection.desktopScope != .subscription
    }

    private var status: String {
        switch store.cliStatus {
        case .unverified: return standaloneVerified ? "身份已核验" : "未核验"
        case .matched: return matched ? "已与桌面一致" : "未核验"
        case .different: return "与桌面不同"
        case .needsLogin: return "需要登录"
        case .otherAuthentication: return "其他认证配置"
        // A limit of this app's checker, not a terminal fault: neutral colour, no "unsupported" alarm.
        case .unsupportedStorage: return "暂未核验"
        }
    }

    private var statusColor: Color {
        switch store.cliStatus {
        case .matched: return matched ? .good : .sub
        case .different, .otherAuthentication: return .warn
        case .unverified, .needsLogin, .unsupportedStorage: return .sub
        }
    }

    private var accountDetail: String? {
        let value = [store.cliProfile, store.cliEmail].compactMap { $0 }.joined(separator: "  ·  ")
        return value.isEmpty ? nil : value
    }

    private var detail: String {
        switch store.cliStatus {
        case .unverified:
            if let accountDetail { return accountDetail }
            if standaloneVerified { return "桌面无订阅账号可比较" }
            return store.cliStatusCheckedAt == nil ? "尚未完成检查" : "上次检查未能核验，原因见 ⓘ"
        case .matched: return matched ? accountDetail ?? "与当前桌面账号一致" : "桌面不是订阅模式，待重新检查"
        case .different: return accountDetail ?? "默认登录账号待确认"
        case .needsLogin: return "未检测到订阅登录"
        case .otherAuthentication: return "可能覆盖订阅"
        case .unsupportedStorage: return accountDetail ?? "切换器暂无法核验；不代表终端有问题"
        }
    }

    private var scopeHelp: String {
        switch store.cliStatus {
        case .unverified:
            if standaloneVerified {
                return "当前桌面为 API 或模式未知，没有可比较的订阅账号；这不表示与桌面一致。"
            }
            return "尚未核验切换器默认保存的 CLI 登录，不据此推断其他终端状态。"
        case .matched:
            guard matched else { return "当前桌面不是订阅模式，上次比较不再适用；请重新检查。" }
            return "默认保存的 CLI 登录已核验，且与当前桌面账号一致。"
        case .different:
            if protection.desktopScope != .subscription {
                return "默认保存的 CLI 登录与桌面状态不同；当前桌面不是订阅账号，无可同步目标。"
            }
            return "默认保存的 CLI 登录与当前桌面账号不同；可点“同步”，同步只处理订阅 OAuth，不改 API key、环境变量或 provider。"
        case .needsLogin:
            return "默认保存的 CLI 订阅登录需要登录；API 与 provider 配置保持原样。"
        case .otherAuthentication:
            return "检测到其他认证配置，可能覆盖订阅。"
        case .unsupportedStorage:
            return "仅支持默认位置的钥匙串或凭据文件；自定义目录等保存方式暂未适配，未核验也未同步。不表示终端有问题，无需重新登录。"
        }
    }

    /// Popover text: the row already shows `detail`, so only add the backend note and the
    /// scope once, then a single short disclaimer.
    private var detailHelp: String {
        var lines = [store.cliStatusDetail, scopeHelp].compactMap { $0 }.filter { !$0.isEmpty }
        var seen = Set<String>()
        lines = lines.filter { seen.insert($0).inserted }
        lines.append("仅针对默认保存的登录，不代表已运行的 CLI 任务，也不保护 CLI 进程。")
        return lines.joined(separator: "\n")
    }

    /// The only inline action is the sync remedy. Checking runs in the background (and from the
    /// footer refresh); a manual check lives in the info popover, so no state grows a button row.
    private var showsActions: Bool { canSync }

    var body: some View {
        // Two tiers inside the strip: identity (icon + title/status + detail) on top, actions on
        // their own row below. The title and status never compete with buttons for width.
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 12, weight: .semibold)).foregroundColor(.claude)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.claude.opacity(0.1)))
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("终端 OAuth").font(.system(size: 12, weight: .semibold)).foregroundColor(.txt)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        Text(status).font(.system(size: 10, weight: .medium))
                            .foregroundColor(statusColor).lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                        Button { showHelp.toggle() } label: {
                            Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(.sub)
                                .frame(width: 20, height: 16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("查看这项状态的说明")
                        .accessibilityLabel("终端登录状态说明")
                        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(detailHelp).font(.system(size: 10.5)).foregroundColor(.txt)
                                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                Text(checkedLine).font(.system(size: 10)).foregroundColor(.sub)
                                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                Divider().opacity(0.6)
                                HStack(spacing: 8) {
                                    Text("后台会定期检查，底部刷新也会检查。").font(.system(size: 10)).foregroundColor(.sub)
                                    Spacer(minLength: 4)
                                    Button {
                                        showHelp = false
                                        Task { await store.verifyDefaultCLI() }
                                    } label: {
                                        Text(checking ? "检查中…" : "立即检查").font(.system(size: 10.5, weight: .medium))
                                            .padding(.horizontal, 10).frame(height: 24)
                                            .foregroundColor(.txt)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(controlsLocked || checking)
                                    .opacity(controlsLocked || checking ? 0.45 : 1)
                                    .help(checkHelp)
                                }
                            }
                            .frame(width: 280, alignment: .leading).padding(12)
                        }
                    }
                    Text(detail).font(.system(size: 10.5)).foregroundColor(.sub)
                        .lineLimit(1).truncationMode(.middle).help(detailHelp)
                        .accessibilityHint(detailHelp)
                }
                if showsActions { actions }
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Dialog and alert live on the container, not on the sync button, so a refresh that hides
        // the button mid-dialog can't swallow the "state changed" notice.
        .confirmationDialog("将默认 CLI 登录同步到 \(syncTarget)？", isPresented: $confirmSync,
                            titleVisibility: .visible) {
            Button("同步") {
                // Re-validate at confirm time; the state may have changed while the dialog was open.
                guard canSync, !controlsLocked, !checking, store.current == syncTarget else {
                    syncStale = true
                    return
                }
                let target = syncTarget
                Task { await store.moveTerminal(to: target) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会先备份当前 CLI 登录，再恢复 \(syncTarget) 的已保存登录并回读核验。不会关闭 CLI 任务，运行中的任务何时采用新登录由 CLI 决定；不改 API 设置。")
        }
        .alert("状态已变化，未同步", isPresented: $syncStale) {
            Button("好") {}
        } message: {
            Text("当前账号或状态已变化，请重新检查后再同步。")
        }
    }

    /// Shown only for a confirmed difference against a subscription desktop: the sync remedy.
    /// Disabled (not hidden) while a check runs, so the row doesn't flicker mid-refresh.
    private var actions: some View {
        HStack(spacing: 6) {
            Button { syncTarget = store.current; confirmSync = true } label: {
                Text("同步到 \(store.current)").font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .foregroundColor(.claude)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color.claude.opacity(hover ? 0.26 : 0.16)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(controlsLocked || checking)
            .opacity(controlsLocked || checking ? 0.45 : 1)
            .help("同步到 \(store.current)：仅同步终端 OAuth 登录；不改 API key、环境变量或 provider 设置")
            .onHover { hover = $0 }
            Spacer(minLength: 0)
        }
    }
}

struct UsageMetric: View {
    let title: String
    let value: Double?
    let reset: String
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(.sub)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(pct(value)).font(.system(size: prominent ? 28 : 22, weight: .bold, design: .rounded))
                Text("%").font(.system(size: prominent ? 12 : 11, weight: .semibold, design: .rounded))
            }
            .foregroundColor(levelColor(value))
            Bar(value: value, color: levelColor(value), height: 3)
            Text(reset).font(.system(size: 9)).foregroundColor(.sub.opacity(0.86))
                .lineLimit(1).minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProfileCard: View {
    let p: Profile
    let active: Bool
    let busy: Bool
    let onSwitch: () -> Void
    @State private var hover = false

    /// Every account card shares one height, so empty / loading / failed cards sit on the same
    /// row rhythm as data cards instead of floating at their own height.
    static let height: CGFloat = 156

    private struct Placeholder {
        let icon: String
        let title: String
        var detail: String?
        var color: Color = .sub
        var spinner = false
    }

    private var placeholder: Placeholder {
        if !p.signedIn { return Placeholder(icon: "person.crop.circle.badge.plus", title: "切换后，在 Claude 中登录") }
        switch p.usageState {
        case .loading: return Placeholder(icon: "", title: "正在读取用量…", spinner: true)
        case .blocked: return Placeholder(icon: "shield.lefthalf.filled", title: "未请求用量", detail: "保护检查通过后再读取")
        case .failed: return Placeholder(icon: "exclamationmark.triangle", title: "用量读取失败",
                                         detail: p.error, color: .warn)
        case .notRequested, .cached, .loaded: return Placeholder(icon: "chart.bar", title: "暂无用量数据")
        }
    }

    @ViewBuilder private func usageFooter(_ snapshot: Snapshot) -> some View {
        let age = ago(snapshot.fetchedAt)
        switch p.usageState {
        case .loading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在更新…")
            }.foregroundColor(.sub.opacity(0.8))
        case .failed:
            Label("刷新失败 · 显示\(age)的缓存", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.warn).lineLimit(1).help(p.error ?? "用量请求失败")
        case .blocked:
            Text("未刷新 · \(age)的缓存").foregroundColor(.sub.opacity(0.8))
                .help("保护检查未通过，本次没有请求用量；原因见顶部提示。")
        case .loaded where p.live:
            // Fresh from the latest round: the footer's round time already says when; stay quiet.
            EmptyView()
        case .loaded:
            Text("\(age)更新").foregroundColor(.sub.opacity(0.8))
        case .notRequested, .cached:
            Text("缓存 · \(age)更新").foregroundColor(.sub.opacity(0.8))
        }
    }

    var body: some View {
        let s = p.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(p.name).font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.txt).lineLimit(1)
                    HStack(spacing: 5) {
                        if let plan = s?.plan {
                            Text(plan).font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 2).fixedSize()
                                .foregroundColor(.sub)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.stroke.opacity(0.7)))
                        }
                        Text(accountLine(p) ?? "")
                            .font(.system(size: 10)).foregroundColor(.sub)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                // The top-right slot is shared: other cards put "切换" here, the current card a plain
                // status mark (dot + text, no fill) so it never reads as a second, selectable control.
                if active {
                    HStack(spacing: 4) {
                        Circle().fill(Color.claude).frame(width: 5, height: 5)
                        Text("当前").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.claude)
                    .padding(.vertical, 4)
                    .help("正在使用的账号")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("当前账号")
                } else {
                    Button(action: onSwitch) {
                        Pill(text: "切换", fg: .txt, bg: hover ? Color(hex: 0x45423C) : .stroke)
                    }
                    .buttonStyle(.plain).disabled(busy).opacity(busy ? 0.45 : 1)
                    .help("检查网络与地区后切换到此账号")
                    .onHover { hover = $0 }
                }
            }

            if p.signedIn, let snapshot = s {
                HStack(alignment: .top, spacing: 12) {
                    UsageMetric(title: "5 小时剩余", value: left(snapshot.session),
                                reset: countdown(snapshot.session?.resetsAt), prominent: true)
                    Rectangle().fill(Color.stroke.opacity(0.8)).frame(width: 1, height: 58)
                    UsageMetric(title: "每周剩余", value: left(snapshot.weekly),
                                reset: snapshot.weekly?.resetsAt.map { "\(weekdayTime($0)) 重置" } ?? "重置时间未知")
                }
                Spacer(minLength: 0)
                usageFooter(snapshot).font(.system(size: 9.5))
                    .frame(height: 12, alignment: .leading)
            } else {
                let ph = placeholder
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    if ph.spinner {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: ph.icon).font(.system(size: 18, weight: .light)).foregroundColor(ph.color)
                    }
                    Text(ph.title).font(.system(size: 10.5, weight: .medium)).foregroundColor(ph.color)
                    if let detail = ph.detail {
                        Text(detail).font(.system(size: 9.5)).foregroundColor(.sub)
                            .multilineTextAlignment(.center).lineLimit(2).help(detail)
                    }
                }
                .frame(maxWidth: .infinity)
                .help(p.usageState == .blocked ? "保护检查未通过，本次没有请求用量；原因见顶部提示。" : "")
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(height: Self.height)
        // Current card: one warm hairline and a slightly lifted surface; the mark above names it.
        .background(RoundedRectangle(cornerRadius: 14).fill(active ? Color.cardHi : Color.card))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(active ? Color.claude.opacity(0.42) : Color.stroke.opacity(0.32), lineWidth: 1))
    }
}

/// The original "add another account" entry: always the last cell of the account grid, at today's
/// compact card height, whatever the account count. Idle it is one button; editing it holds the name
/// field, Return adds, Esc or 取消 leaves without adding.
struct AddAccountEntry: View {
    let onAdd: (String) -> Void
    @State private var editing = false
    @State private var name = ""
    @State private var hover = false
    @FocusState private var focused: Bool
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if editing { editor } else { idle }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ProfileCard.height)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color.card.opacity(editing || hover ? 1 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color.stroke.opacity(editing ? 0.6 : 1),
                    style: StrokeStyle(lineWidth: 1, dash: editing ? [] : [4, 3])))
    }

    private var idle: some View {
        Button { editing = true } label: {
            VStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 17, weight: .light))
                Text("添加账号").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(hover ? .txt : .sub)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("新建一个空账号；切换过去后在 Claude 中登录")
    }

    private var field: some View {
        TextField("账号名称，如 客户 A", text: $name)
            .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundColor(.txt)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: reset)
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.bg))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.stroke, lineWidth: 1))
            .onAppear { DispatchQueue.main.async { focused = true } }
            .accessibilityLabel("新账号名称")
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("取消", action: reset).buttonStyle(.plain)
                .font(.system(size: 10.5)).foregroundColor(.sub)
            Button("添加", action: commit).buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(valid ? .white : .sub)
                .padding(.horizontal, 11).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(valid ? Color.claude : Color.stroke))
                .disabled(!valid)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("新账号").font(.system(size: 11, weight: .semibold)).foregroundColor(.sub)
            field
            HStack { Spacer(minLength: 0); buttons }
        }
        .padding(.horizontal, 14)
    }

    func commit() {
        guard valid else { return }
        onAdd(name)
        reset()
    }

    func reset() {
        name = ""
        focused = false
        editing = false
    }
}

struct FooterButton: View {
    let icon: String; let help: String; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundColor(hover ? .txt : .sub).frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.stroke : .clear))
        }.buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

@MainActor
struct Panel: View {
    @ObservedObject var store: Store
    @ObservedObject var protection: ProtectionController
    @State private var quitHover = false
    let cols = [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)]

    /// What the last refresh round actually achieved. `lastRefresh` only moves when a round finishes
    /// (blocked rounds don't move it), so per-card failures and blocks are surfaced instead of "刚刚".
    private var refreshSummary: (text: String, color: Color, help: String) {
        if store.profiles.contains(where: { $0.usageState == .blocked }) {
            return ("用量未刷新", .warn, "网络门禁未通过，本轮没有请求用量；原因见上方提示。卡片显示的是缓存。")
        }
        guard let last = store.lastRefresh else {
            return ("尚未刷新", .sub, "还没有完成过一轮刷新")
        }
        let failed = store.profiles.filter { $0.usageState == .failed }.count
        if failed > 0 {
            return ("最近刷新：\(ago(last)) · \(failed) 个失败", .warn,
                    "最近一次刷新动作完成于\(ago(last))；其中有账号用量读取失败，对应卡片显示缓存")
        }
        return ("最近刷新：\(ago(last))", .sub,
                "最近一次刷新动作（账号用量与默认 CLI 登录核验）的完成时间。\n各账号是否读取成功以卡片上的提示为准；这不是后台守卫的检查时间。")
    }

    private var importLanguageBinding: Binding<String> {
        Binding(get: { store.importLanguage }, set: { store.setImportLanguage($0) })
    }
    init(store: Store) {
        self.store = store
        self.protection = store.protection
    }

    /// Cards in their original order, then the add entry as the last grid cell.
    private var accountGrid: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(store.profiles) { p in
                ProfileCard(p: p, active: p.name == store.current, busy: store.busy != nil || store.refreshing) {
                    Task { await store.switchTo(p.name) }
                }
            }
            AddAccountEntry { store.addProfile($0) }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Header(store: store, protection: protection) {
                Task { await store.openProtectedClaude() }
            }
            TerminalProtectionCard(store: store, controller: protection, busy: store.busy != nil)
            if let b = store.banner {
                Label("上次操作：\(b)", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11))
                    .foregroundColor(.warn).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.warn.opacity(0.1)))
            }
            if let offer = store.desktopOnlyOffer {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.warn)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CLI 准备未完成，可选择仅切换桌面")
                                .font(.system(size: 10.5, weight: .medium)).foregroundColor(.txt)
                            Text("目标：\(offer.target)；CLI 保持原样")
                                .font(.system(size: 10)).foregroundColor(.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        Button("取消") { store.desktopOnlyOffer = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.sub)
                        Button("仅切换桌面") {
                            Task { await store.confirmDesktopOnlySwitch() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.claude)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.claude.opacity(0.1)))
                        .disabled(store.busy != nil || store.refreshing)
                        .opacity(store.busy == nil && !store.refreshing ? 1 : 0.45)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.card.opacity(0.65)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.stroke.opacity(0.5), lineWidth: 1))
                .help("原因：\(offer.reason)\n仅从 \(offer.source) 切换到 \(offer.target)；CLI 保持原样。")
            }
            // Capacity counts every grid cell, including the add entry: more than two rows (4 cells) scrolls.
            if store.profiles.count + 1 > 2 * cols.count {
                ScrollView { accountGrid }.frame(height: 2 * ProfileCard.height + 10 + 44) // third row peeks to signal scrolling
            } else {
                accountGrid
            }
            HStack(spacing: 7) {
                FooterButton(icon: "folder", help: "显示账号目录") {
                    if !store.isDemo { NSWorkspace.shared.activateFileViewerSelecting([parkDir]) }
                }
                Rectangle().fill(Color.stroke).frame(width: 1, height: 18)
                if let b = store.busy {
                    ProgressView().controlSize(.small)
                    Text(b).font(.system(size: 11, weight: .medium)).foregroundColor(.claude).lineLimit(1)
                } else if store.refreshing {
                    ProgressView().controlSize(.small)
                    Text("刷新中…").font(.system(size: 11, weight: .medium)).foregroundColor(.sub)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        let summary = refreshSummary
                        HStack(spacing: 5) {
                            Image(systemName: summary.color == .sub ? "clock" : "exclamationmark.triangle")
                                .font(.system(size: 10))
                            Text(summary.text).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .foregroundColor(summary.color)
                        .help(summary.help)
                        .accessibilityElement(children: .combine)
                    }
                }
                Spacer(minLength: 4)
                if store.sessionMigrationEnabled {
                    FooterButton(icon: "doc.on.doc", help: "导入 Claude Code 会话") { CopyWindow.show(store) }
                }
                FooterButton(icon: "arrow.clockwise",
                             help: "刷新：先过网络门禁，再读取账号用量并核验默认 CLI 登录\n不改保护设置、不启用保护、不纳入桌面") {
                    Task { await store.refresh() }
                }
                FooterButton(icon: store.openAtLogin ? "sunrise.fill" : "sunrise",
                             help: store.openAtLogin ? "已设置登录时打开界面，点击关闭" : "设置登录时打开界面") {
                    store.toggleOpenAtLogin()
                }
                // Rarely used preferences live here rather than on the import page. Only the session
                // import page is bilingual so far; the label says so instead of implying app-wide English.
                Menu {
                    Picker("会话导入页语言（仅导入页）", selection: importLanguageBinding) {
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 13, weight: .medium)).foregroundColor(.sub)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize().frame(width: 28, height: 28)
                .help("偏好：会话导入页语言（其余界面暂仅中文）")
                Rectangle().fill(Color.stroke).frame(width: 1, height: 18)
                Button { NSApp.terminate(nil) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "power").font(.system(size: 11, weight: .medium))
                        Text("退出界面").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(quitHover ? .txt : .sub)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color.stroke.opacity(quitHover ? 0.7 : 0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("退出界面，不改变后台保护开关")
                .disabled(store.busy != nil || protection.working)
                .onHover { quitHover = $0 }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
        }
        .padding(12)
        .frame(width: 500)
        .background(Color.bg)
        .preferredColorScheme(.dark)
    }
}

@MainActor
struct DemoPanel: View {
    let store: Store
    let initialViewportHeight: CGFloat
    let maxContentHeight: CGFloat
    let onContentHeightChange: (CGFloat) -> Void

    var body: some View {
        PanelViewport(store: store,
                      initialViewportHeight: initialViewportHeight,
                      maxContentHeight: maxContentHeight,
                      onContentHeightChange: onContentHeightChange)
    }
}
