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
    var body: some View {
        let a = store.active, s = a?.snapshot
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Color.claude.opacity(0.13))
                RoundedRectangle(cornerRadius: 11).stroke(Color.claude.opacity(0.35), lineWidth: 1)
                Image(systemName: "sparkles").font(.system(size: 19, weight: .semibold)).foregroundColor(.claude)
            }.frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Switcher").font(.system(size: 10.5, weight: .medium)).foregroundColor(.sub)
                HStack(spacing: 7) {
                    Text(store.current).font(.system(size: 19, weight: .bold)).foregroundColor(.txt).lineLimit(1)
                    Text("当前账号").font(.system(size: 9.5, weight: .medium)).foregroundColor(.claude)
                }
                Text([s?.email ?? (a?.signedIn == false ? "尚未登录" : "账号信息读取中"), s?.plan]
                    .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10.5)).foregroundColor(.sub).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text("Claude 桌面版").font(.system(size: 9.5)).foregroundColor(.sub)
                HStack(spacing: 5) {
                    Circle().fill(store.claudeRunning ? Color.good : Color.sub).frame(width: 6, height: 6)
                    Text(store.claudeRunning ? "运行中" : "已关闭")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(store.claudeRunning ? .good : .sub)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
    }
}

struct TerminalStrip: View {
    @ObservedObject var store: Store
    @State private var hover = false
    var body: some View {
        let mismatch = store.cliProfile != store.current
        let status = store.cliEmail == nil ? "未检测到登录" : store.cliProfile == nil ? "账号待确认" : mismatch ? "与桌面不同" : "已与桌面同步"
        let detail = store.cliEmail.map { "\(store.cliProfile ?? "未知账号")  ·  \($0)" }
            ?? "未检测到 OAuth；API 与 provider 配置保持原样"
        HStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 12, weight: .semibold)).foregroundColor(.claude)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.claude.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("终端 OAuth").font(.system(size: 12, weight: .semibold)).foregroundColor(.txt)
                    Text(status).font(.system(size: 10, weight: .medium))
                        .foregroundColor(store.cliEmail == nil ? .sub : mismatch ? .warn : .good)
                }
                Text(detail).font(.system(size: 10.5)).foregroundColor(.sub)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if mismatch {
                Button { Task { await store.moveTerminal(to: store.current) } } label: {
                    Text("同步到 \(store.current)").font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .foregroundColor(.claude)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Color.claude.opacity(hover ? 0.22 : 0.13)))
                }
                .buttonStyle(.plain).disabled(store.busy != nil || store.refreshing)
                .opacity(store.busy == nil && !store.refreshing ? 1 : 0.45)
                .help("仅同步终端 OAuth 登录；不改 API key、环境变量或 provider 设置")
                .onHover { hover = $0 }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
    }
}

struct UsageMetric: View {
    let title: String
    let value: Double?
    let reset: String
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(.sub)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(pct(value)).font(.system(size: prominent ? 30 : 23, weight: .bold, design: .rounded))
                Text("%").font(.system(size: prominent ? 13 : 11, weight: .semibold, design: .rounded))
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

    var body: some View {
        let s = p.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.system(size: 14, weight: .semibold))
                            .foregroundColor(active ? .claude : .txt).lineLimit(1)
                        if active { Pill(text: "当前", fg: .claude, bg: .claude.opacity(0.12)) }
                    }
                    HStack(spacing: 5) {
                        if let plan = s?.plan {
                            Text(plan).font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 2).fixedSize()
                                .foregroundColor(.sub)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.stroke.opacity(0.7)))
                        }
                        Text(p.signedIn ? (s?.email ?? "账号信息读取中") : "尚未登录")
                            .font(.system(size: 10)).foregroundColor(.sub)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if !active {
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
                    Rectangle().fill(Color.stroke.opacity(0.8)).frame(width: 1, height: 73)
                    UsageMetric(title: "每周剩余", value: left(snapshot.weekly),
                                reset: snapshot.weekly?.resetsAt.map { "\(weekdayTime($0)) 重置" } ?? "重置时间未知")
                }
                .padding(.top, 2)
                Group {
                    if let e = p.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5)).foregroundColor(.warn)
                            .lineLimit(1).truncationMode(.tail).help(e)
                    } else {
                        Text(p.live ? "\(ago(snapshot.fetchedAt))更新" : "缓存 · \(ago(snapshot.fetchedAt))更新")
                            .font(.system(size: 9.5)).foregroundColor(.sub.opacity(0.8))
                    }
                }
                .frame(height: 12, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 4)
                VStack(spacing: 7) {
                    Image(systemName: p.signedIn ? "arrow.triangle.2.circlepath" : "person.crop.circle.badge.plus")
                        .font(.system(size: 22, weight: .light)).foregroundColor(.sub)
                    Text(p.error ?? (p.signedIn ? "正在读取用量…" : "切换后，在 Claude 中登录"))
                        .font(.system(size: 10.5)).foregroundColor(p.error == nil ? .sub : .warn)
                        .multilineTextAlignment(.center).lineLimit(2)
                }.frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(height: p.signedIn && s != nil ? 188 : 132)
        .background(RoundedRectangle(cornerRadius: 14).fill(active ? Color.cardHi : Color.card))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(active ? Color.claude.opacity(0.65) : Color.stroke.opacity(0.32), lineWidth: 1))
        .overlay(alignment: .leading) {
            if active { Capsule().fill(Color.claude).frame(width: 3, height: 40) }
        }
    }
}

struct AddAccountCard: View {
    let onAdd: (String) -> Void
    @State private var editing = false
    @State private var name = ""
    @State private var hover = false
    @FocusState private var focused: Bool
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    Label("新账号", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.sub)
                    TextField("名称，例如：客户 A", text: $name)
                        .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundColor(.txt)
                        .focused($focused).onSubmit(commit)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.bg))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.stroke, lineWidth: 1))
                    HStack(spacing: 10) {
                        Spacer()
                        Button("取消", action: reset).buttonStyle(.plain)
                            .font(.system(size: 10.5)).foregroundColor(.sub)
                        Button("添加", action: commit).buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(valid ? .white : .sub)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(valid ? Color.claude : Color.stroke))
                            .disabled(!valid)
                    }
                }
                .padding(13)
            } else {
                Button { editing = true } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .light))
                        Text("添加账号").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 132)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.card.opacity(editing || hover ? 1 : 0.5)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color.stroke.opacity(editing ? 0.9 : hover ? 0.75 : 0.5), lineWidth: 1))
        .onHover { hover = $0 }
        .onChange(of: editing) { value in if value { focused = true } }
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
    let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    init(store: Store) {
        self.store = store
        self.protection = store.protection
    }

    private var accountGrid: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(store.profiles) { p in
                ProfileCard(p: p, active: p.name == store.current, busy: store.busy != nil || store.refreshing) {
                    Task { await store.switchTo(p.name) }
                }
            }
            AddAccountCard { store.addProfile($0) }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Header(store: store)
            ProtectionStrip(controller: protection, busy: store.busy != nil) {
                Task { await store.openProtectedClaude() }
            }
            TerminalStrip(store: store)
            if let b = store.banner {
                Label(b, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11))
                    .foregroundColor(.warn).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.warn.opacity(0.1)))
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text("账号").font(.system(size: 13, weight: .semibold)).foregroundColor(.txt)
                    Text("\(store.profiles.count) 个").font(.system(size: 10)).foregroundColor(.sub)
                }
                .padding(.horizontal, 2)
                if store.profiles.count + 1 > 4 {
                    ScrollView { accountGrid }.frame(height: 386)
                } else {
                    accountGrid
                }
            }
            HStack(spacing: 7) {
                FooterButton(icon: "folder", help: "显示账号目录") {
                    if !store.isDemo { NSWorkspace.shared.activateFileViewerSelecting([parkDir]) }
                }
                Rectangle().fill(Color.stroke).frame(width: 1, height: 18)
                if let b = store.busy {
                    ProgressView().controlSize(.small)
                    Text(b).font(.system(size: 11, weight: .medium)).foregroundColor(.claude).lineLimit(1)
                } else {
                    Image(systemName: "clock").font(.system(size: 10)).foregroundColor(.sub)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(ago(store.lastRefresh)).font(.system(size: 11, weight: .medium)).foregroundColor(.sub)
                            .help("上次用量刷新时间")
                    }
                }
                Spacer(minLength: 4)
                FooterButton(icon: "arrow.clockwise", help: "刷新账号与用量") { Task { await store.refresh() } }
                FooterButton(icon: store.openAtLogin ? "sunrise.fill" : "sunrise",
                             help: store.openAtLogin ? "已设置登录时打开界面，点击关闭" : "设置登录时打开界面") {
                    store.toggleOpenAtLogin()
                }
                Rectangle().fill(Color.stroke).frame(width: 1, height: 18)
                VStack(alignment: .trailing, spacing: 4) {
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
                    .help("仅关闭界面，不更改保护状态")
                    .disabled(store.busy != nil || protection.working)
                    .onHover { quitHover = $0 }
                    Text(protection.exitStatusText)
                        .font(.system(size: 8.5))
                        .foregroundColor(protection.enabled && !protection.guardOnline ? .warn : .sub)
                        .lineLimit(1)
                }
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

// MARK: - Deferred copy threads prototype (no product entry)

struct CopyThreadsView: View {
    @ObservedObject var store: Store
    @State private var from = ""
    @State private var to = ""
    @State private var threads: [ThreadInfo] = []
    @State private var picked = Set<String>()
    @State private var query = ""
    @State private var showArchived = false
    @State private var destinations: [ThreadDestination] = []
    @State private var destinationID = ""
    @State private var scanNote: String?
    @State private var status: String?

    var names: [String] { store.profiles.map(\.name) }
    var visible: [ThreadInfo] {
        threads.filter { (showArchived || !$0.archived)
            && (query.isEmpty || "\($0.title) \($0.cwd)".localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                picker("From", $from)
                Image(systemName: "arrow.right").foregroundColor(.claude)
                picker("To", $to)
                Spacer()
            }
            if !destinations.isEmpty {
                Picker("目标组织", selection: $destinationID) {
                    Text("请选择目标组织").tag("")
                    ForEach(destinations) { Text($0.label).tag($0.id) }
                }
            }
            if let scanNote { Text(scanNote).font(.system(size: 11)).foregroundColor(.warn) }
            HStack {
                TextField("Search threads or projects", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Archived", isOn: $showArchived).toggleStyle(.checkbox)
            }
            HStack {
                Button(allPicked ? "Select none" : "Select all") {
                    if allPicked { visible.forEach { picked.remove($0.id) } } else { visible.forEach { picked.insert($0.id) } }
                }.buttonStyle(.link)
                Spacer()
                Text("\(picked.count) selected · \(visible.count) shown").font(.system(size: 11)).foregroundColor(.sub)
            }
            List(visible) { t in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { picked.contains(t.id) },
                                             set: { on in if on { picked.insert(t.id) } else { picked.remove(t.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.txt).lineLimit(1)
                        Text(t.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11)).foregroundColor(.sub).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(t.project).font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 3)
                        .foregroundColor(.sub).background(RoundedRectangle(cornerRadius: 5).fill(Color.stroke))
                    Text(ago(t.lastActivity)).font(.system(size: 11)).foregroundColor(.sub).frame(width: 60, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { if picked.contains(t.id) { picked.remove(t.id) } else { picked.insert(t.id) } }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .overlay { if visible.isEmpty { Text(from.isEmpty ? "" : "No threads in \(from)").foregroundColor(.sub) } }
            HStack {
                if let b = store.busy {
                    ProgressView().controlSize(.small); Text(b).foregroundColor(.claude)
                } else if let s = status {
                    Text(s).font(.system(size: 12)).foregroundColor(s.hasPrefix("Copied") ? .good : .warn).lineLimit(2)
                }
                Spacer()
                Button("Copy \(picked.count) to \(to)") {
                    let sel = threads.filter { picked.contains($0.id) }
                    Task {
                        status = await store.copyThreads(sel, to: to, destinationID: destinationID)
                        if status?.hasPrefix("Copied") == true { picked.removeAll() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || from == to || store.busy != nil || destinationID.isEmpty)
            }
            if to == store.current && store.claudeRunning {
                Text("Claude will restart so \(to) picks up the copied threads.").font(.system(size: 11)).foregroundColor(.sub)
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 520)
        .background(Color.bg)
        .preferredColorScheme(.dark)
        .onAppear {
            to = store.current
            from = names.first { $0 != to } ?? to
            load(); loadDestinations()
        }
        .onChange(of: from) { _ in load() }
        .onChange(of: to) { _ in loadDestinations() }
    }

    var allPicked: Bool { !visible.isEmpty && visible.allSatisfy { picked.contains($0.id) } }

    func load() {
        picked.removeAll(); status = nil; scanNote = nil
        do {
            let scan = try store.scanThreads(from)
            threads = scan.threads
            if scan.unreadable > 0 { scanNote = "\(scan.unreadable) 个索引无法读取，未纳入复制。" }
        } catch { threads = []; scanNote = error.localizedDescription }
    }
    func loadDestinations() {
        destinationID = ""
        do {
            destinations = try store.threadDestinations(to)
            if destinations.count == 1 { destinationID = destinations[0].id }
        } catch { destinations = []; status = error.localizedDescription }
    }

    func picker(_ label: String, _ sel: Binding<String>) -> some View {
        Picker(label, selection: sel) { ForEach(names, id: \.self) { Text($0).tag($0) } }.frame(width: 190)
    }
}

enum CopyWindow {
    static var window: NSWindow?
    @MainActor static func show(_ store: Store) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Copy Claude Code Threads"
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentViewController = NSHostingController(rootView: CopyThreadsView(store: store))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
