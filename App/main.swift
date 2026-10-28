import AppKit
import SwiftUI
import CryptoKit
import ServiceManagement
import Security
import Combine
import SwitcherCore

// Claude Switcher — menu bar app that swaps Claude Desktop's data folder between accounts
// and shows live plan usage for each one.
//
// Active profile lives at ~/Library/Application Support/Claude (a real dir).
// Inactive profiles are parked at ~/Library/Application Support/Claude-Profiles/<name>.
// Switching = quit Claude, rename dirs (instant, same volume), relaunch.
// Usage comes from each profile's own OAuth token (decrypted from its config.json).

let bundleID = "com.anthropic.claudefordesktop"
let fm = FileManager.default
let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let liveDir = support.appendingPathComponent("Claude")
let parkDir = support.appendingPathComponent("Claude-Profiles")
let currentFile = parkDir.appendingPathComponent(".current")
let cacheDir = parkDir.appendingPathComponent(".cache")
let defaultProfiles = ["Personal", "Business"]
let demoMode = CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewMode") as? Bool == true
let demoPopover = demoMode && (CommandLine.arguments.contains("--demo-popover")
    || Bundle.main.object(forInfoDictionaryKey: "CSPreviewPopover") as? Bool == true)

// MARK: - Data

struct Window: Codable { var used: Double; var resetsAt: Date? }

struct Snapshot: Codable {
    var email: String?
    var accountID: String?
    var organizationID: String?
    var identityTokenDigest: String?
    var name: String?
    var plan: String?
    var session: Window?
    var weekly: Window?
    var weeklyOpus: Window?
    var extraEnabled: Bool?
    var fetchedAt: Date
    var identity: CLIIdentity { CLIIdentity(accountID: accountID, organizationID: organizationID, email: email) }
}

enum ProfileUsageState: Equatable, Sendable { case notRequested, loading, cached, loaded, blocked, failed }

struct Profile: Identifiable {
    var id: String { name }
    let name: String
    var snapshot: Snapshot?
    var signedIn: Bool
    var error: String?
    var usageState: ProfileUsageState = .notRequested
    var live: Bool { usageState == .loaded && error == nil && snapshot.map { Date().timeIntervalSince($0.fetchedAt) < 600 } == true }
    mutating func beginUsageRefresh() { usageState = .loading; error = nil }
    mutating func blockUsageRefresh(_ reason: String) {
        usageState = .blocked
        if snapshot == nil { error = reason }
    }
    mutating func finishUsageRefresh(_ result: Result<Snapshot, Error>?) {
        switch result {
        case nil: signedIn = false; error = nil; usageState = .notRequested
        case .success(let value)?: snapshot = value; signedIn = true; error = nil; usageState = .loaded
        case .failure(let value)?: error = value.localizedDescription; usageState = .failed
        }
    }
}

func currentProfile() -> String {
    (try? String(contentsOf: currentFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultProfiles[0]
}

func confirmedCurrentProfile() throws -> String { try ProfileTransaction.currentName(at: currentFile) }

func profileDir(_ name: String) -> URL {
    name == currentProfile() ? liveDir : parkDir.appendingPathComponent(name)
}

func allProfileNames() -> [String] {
    let cur = currentProfile()
    let parked = ((try? fm.contentsOfDirectory(atPath: parkDir.path)) ?? [])
        .filter { !$0.hasPrefix(".") }
    var names = [cur] + parked.filter { $0 != cur }
    // stable order: defaults first, then alphabetical
    names.sort { a, b in
        let ia = defaultProfiles.firstIndex(of: a) ?? 99, ib = defaultProfiles.firstIndex(of: b) ?? 99
        return ia != ib ? ia < ib : a < b
    }
    return names
}

// MARK: - Token decryption (Electron safeStorage: "v10" + AES-128-CBC, PBKDF2-SHA1 "saltysalt")

let desktopTokenReader = DesktopTokenReader()

func err(_ s: String) -> NSError { NSError(domain: "switcher", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

func token(for directory: URL, allowExpired: Bool = false) async throws -> String? {
    try await desktopTokenReader.read(directory: directory, allowExpired: allowExpired)
}

func parseDate(_ s: Any?) -> Date? {
    guard var s = s as? String else { return nil }
    if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" }) {
        s.removeSubrange(dot..<tz)
    }
    return ISO8601DateFormatter().date(from: s)
}

func window(_ o: Any?) -> Window? {
    guard let d = o as? [String: Any], let u = d["utilization"] as? Double else { return nil }
    return Window(used: u, resetsAt: parseDate(d["resets_at"]))
}

func getJSON(_ path: String, _ tok: String) async throws -> [String: Any] {
    var r = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(path)")!)
    r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
    r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    r.setValue("claude-switcher/1.0", forHTTPHeaderField: "User-Agent")
    r.timeoutInterval = 15
    let (data, resp) = try await URLSession.shared.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw err(code == 401 ? "登录已过期，请在对应客户端确认登录后重试。" : "API error \(code)") }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

func planName(_ org: [String: Any]?) -> String? {
    let tier = (org?["rate_limit_tier"] as? String ?? "").lowercased()
    let type = (org?["organization_type"] as? String ?? "").lowercased()
    if tier.contains("20x") { return "Max 20x" }
    if tier.contains("5x") { return "Max 5x" }
    if type.contains("enterprise") { return "Enterprise" }
    if type.contains("team") { return "Team" }
    if type.contains("max") { return "Max" }
    if type.contains("pro") { return "Pro" }
    return type.isEmpty ? nil : type.capitalized
}

func fetchSnapshot(_ tok: String) async throws -> Snapshot {
    async let u = getJSON("usage", tok)
    async let p = getJSON("profile", tok)
    let (usage, prof) = try await (u, p)
    let identity = CLIIdentity.profile(prof)
    let org = prof["organization"] as? [String: Any]
    return Snapshot(email: identity.email,
                    accountID: identity.accountID, organizationID: identity.organizationID,
                    identityTokenDigest: desktopTokenDigest(tok),
                    name: org?["name"] as? String,
                    plan: planName(org),
                    session: window(usage["five_hour"]),
                    weekly: window(usage["seven_day"]),
                    weeklyOpus: window(usage["seven_day_opus"]),
                    extraEnabled: (usage["extra_usage"] as? [String: Any])?["is_enabled"] as? Bool,
                    fetchedAt: Date())
}

func loadCache(_ name: String) -> Snapshot? {
    guard ProfileTransaction.validName(name) else { return nil }
    guard let d = try? Data(contentsOf: cacheDir.appendingPathComponent("\(name).json")) else { return nil }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    return try? dec.decode(Snapshot.self, from: d)
}

func saveCache(_ name: String, _ s: Snapshot) {
    guard ProfileTransaction.validName(name) else { return }
    try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let output = cacheDir.appendingPathComponent("\(name).json")
    try? enc.encode(s).write(to: output, options: .atomic)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
}

func desktopTokenDigest(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var current = "Personal"
    @Published var claudeRunning = false
    @Published var busy: String?
    @Published var lastRefresh: Date?
    @Published var banner: String?
    @Published var openAtLogin = false
    @Published var cliProfile: String?     // profile the terminal `claude` is logged in as
    @Published var cliEmail: String?
    @Published var cliStatus: CLILoginStatus = .unverified
    @Published var cliStatusDetail: String?
    @Published var cliStandaloneVerified = false
    @Published var cliStatusRefreshing = false
    @Published var cliStatusCheckedAt: Date?
    var cliStatusGeneration = 0
    var cliScopeObservation: AnyCancellable?
    @Published var desktopOnlyOffer: DesktopOnlySwitchOffer?
    @Published private(set) var importLanguage = "zh"
    func setImportLanguage(_ value: String) {
        guard ["zh", "en"].contains(value), value != importLanguage else { return }
        importLanguage = value
        if !isDemo { UserDefaults.standard.set(value, forKey: "importInterfaceLanguage") }
    }
    var onChange: (() -> Void)?
    var onShowAccounts: (() -> Void)?
    func returnToAccounts() { onShowAccounts?() }
    let protection: ProtectionController
    let isDemo: Bool
    var sessionMigrationEnabled: Bool { true }
    @Published private(set) var refreshing = false
    private var desktopObservation: DesktopLifecycleObservation?

    /// Fake accounts for README screenshots — touches no files, keychain or network.
    init(demo: Bool) {
        isDemo = true
        protection = ProtectionController(demo: true)
        let now = Date()
        func snap(_ email: String, _ plan: String, _ s: Double, _ sh: Double, _ w: Double, _ wh: Double) -> Snapshot {
            Snapshot(email: email, name: nil, plan: plan,
                     session: Window(used: s, resetsAt: now.addingTimeInterval(sh * 3600)),
                     weekly: Window(used: w, resetsAt: now.addingTimeInterval(wh * 3600)),
                     weeklyOpus: nil, extraEnabled: false, fetchedAt: now)
        }
        current = "Personal"
        cliProfile = "Personal"
        cliEmail = "ada@lovelace.dev"
        claudeRunning = true
        if Bundle.main.object(forInfoDictionaryKey: "CSPreviewDesktopStopped") as? Bool == true {
            claudeRunning = false
        }
        lastRefresh = now
        profiles = [
            Profile(name: "Personal", snapshot: snap("ada@lovelace.dev", "Max 5x", 28, 3.3, 61, 50), signedIn: true),
            Profile(name: "Business", snapshot: snap("ada@analytical.co", "Team", 86, 1.2, 74, 98), signedIn: true),
            Profile(name: "Side Project", snapshot: nil, signedIn: false),
        ]
        for index in profiles.indices {
            profiles[index].usageState = profiles[index].snapshot == nil ? .notRequested : .loaded
            profiles[index].snapshot?.accountID = "demo-account-" + profiles[index].name
            profiles[index].snapshot?.organizationID = "demo-org-" + profiles[index].name
        }
        cliStatus = .matched
        cliStatusCheckedAt = now
        if Bundle.main.object(forInfoDictionaryKey: "CSPreviewCLIUnverified") as? Bool == true {
            cliStatus = .unverified; cliStatusCheckedAt = nil
        }
        if Bundle.main.object(forInfoDictionaryKey: "CSPreviewCLIRefreshing") as? Bool == true {
            cliStatusRefreshing = true
        }
        cliStatusDetail = "演示：默认保存登录与桌面一致，不表示已运行的 CLI 会话。"
        if cliStatus == .unverified { cliStatusDetail = nil }
        if protection.desktopScope != .subscription {
            cliStatus = .unverified; cliStandaloneVerified = true; cliProfile = nil
            cliStatusDetail = nil
        }
        // Model an externally changed terminal login only when explicitly requested for QA.
        if CommandLine.arguments.contains("--demo-cli-mismatch") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewCLIMismatch") as? Bool == true {
            cliProfile = "Business"
            cliEmail = profiles.first { $0.name == cliProfile }?.snapshot?.email
            cliStatus = .different
        }
        if CommandLine.arguments.contains("--demo-many") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewManyAccounts") as? Bool == true {
            profiles += (1...9).map { number in
                Profile(name: "演示账号 \(number) · 较长名称", snapshot: snap("demo\(number)@example.com", "Max", 20, 2, 35, 72), signedIn: true)
            }
        }
        if let state = Bundle.main.object(forInfoDictionaryKey: "CSPreviewUsageState") as? String,
           let index = profiles.firstIndex(where: { $0.name == "Business" }) {
            profiles[index].snapshot = nil
            profiles[index].usageState = state == "loading" ? .loading : state == "failed" ? .failed : state == "blocked" ? .blocked : .notRequested
            profiles[index].error = state == "blocked" ? "演示：保护检查未通过，尚未获取用量。" : state == "failed" ? "演示：用量请求失败。" : nil
        }
        observeCLIStatusScope()
    }

    func toggleOpenAtLogin() {
        if isDemo { openAtLogin.toggle(); return }
        do {
            if openAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { banner = "Open at login failed: \(error.localizedDescription)" }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    init() {
        isDemo = false
        protection = ProtectionController()
        observeCLIStatusScope()
        let savedLanguage = UserDefaults.standard.string(forKey: "importInterfaceLanguage") ?? "zh"
        importLanguage = ["zh", "en"].contains(savedLanguage) ? savedLanguage : "zh"
        openAtLogin = SMAppService.mainApp.status == .enabled
        try? fm.createDirectory(at: parkDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: currentFile.path) {
            try? defaultProfiles[0].write(to: currentFile, atomically: true, encoding: .utf8)
        }
        for p in defaultProfiles where p != currentProfile() {
            try? fm.createDirectory(at: parkDir.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        reloadList()
        desktopObservation = DesktopLifecycleObservation(center: NSWorkspace.shared.notificationCenter) { [weak self] note in
            MainActor.assumeIsolated {
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == bundleID else { return }
                self?.reloadList(); self?.protection.refreshStatus()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in await self.refresh() } }
        Task { await refresh() }
    }

    var active: Profile? { profiles.first { $0.name == current } }

    /// Opening a panel updates local facts only; startup, the timer and explicit refresh do the I/O round.
    func panelWillOpen() {
        reloadList()
        protection.refreshStatus()
    }


    func reloadList() {
        guard !isDemo else { return }
        let observedProfile = currentProfile()
        if current != observedProfile { current = observedProfile; invalidateCLIStatus() }
        claudeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        profiles = allProfileNames().map { n in
            if let existing = profiles.first(where: { $0.name == n }) { return existing }
            let snapshot = loadCache(n)
            return Profile(name: n, snapshot: snapshot, signedIn: true, usageState: snapshot == nil ? .notRequested : .cached)
        }
        onChange?()
    }

    func refresh() async {
        guard !isDemo, !refreshing, busy == nil else { return }
        refreshing = true
        defer { refreshing = false }
        reloadList()
        // Usage calls carry account tokens too; they must not bypass the region gate.
        let decision = await protection.preflight()
        guard decision.allowed else {
            banner = decision.message
            for index in profiles.indices { profiles[index].blockUsageRefresh(decision.message) }
            // API Desktop is outside the subscription Desktop gate. The default CLI
            // can still be verified through its own network/registration gate.
            await refreshCLI(verify: decision.reason == .unsupportedMode); onChange?()
            return
        }
        banner = nil
        for index in profiles.indices { profiles[index].beginUsageRefresh() }
        await withTaskGroup(of: (String, Result<Snapshot, Error>?).self) { g in
            for p in profiles {
                let dir = profileDir(p.name)
                g.addTask {
                    do {
                        guard let tok = try await token(for: dir) else { return (p.name, nil) }
                        return (p.name, .success(try await fetchSnapshot(tok)))
                    } catch { return (p.name, .failure(error)) }
                }
            }
            for await (name, res) in g {
                guard let i = profiles.firstIndex(where: { $0.name == name }) else { continue }
                profiles[i].finishUsageRefresh(res)
                if case .success(let snapshot)? = res { saveCache(name, snapshot) }
                if case .failure(let error)? = res, error.localizedDescription.contains("Keychain") { banner = error.localizedDescription }
            }
        }
        await refreshCLI(verify: true)
        lastRefresh = Date()
        onChange?()
    }

    func addProfile(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard ProfileTransaction.validName(name),
              !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            banner = "账号名称为空、重复或包含不支持的字符。"; return
        }
        if isDemo { profiles.append(Profile(name: name, snapshot: nil, signedIn: false)); return }
        try? fm.createDirectory(at: parkDir.appendingPathComponent(name), withIntermediateDirectories: true)
        reloadList()
        Task { await refresh() }
    }

    func openProtectedClaude() async {
        guard busy == nil else { return }
        banner = nil
        busy = "检查网络与地区…"
        defer { busy = nil }
        let decision = await protection.preflight()
        guard decision.allowed else { banner = decision.message; return }
        if !isDemo {
            do { try await launchProtectedDesktop(files: protection.files); protection.refreshStatus() } catch { banner = "打开 Claude 失败：" + error.localizedDescription }
        }
        reloadAfterOperation()
    }

    func switchTo(_ target: String) async {
        guard busy == nil else { return }
        desktopOnlyOffer = nil
        banner = nil
        guard !refreshing else { banner = "用量正在刷新，请稍后切换账号。"; return }
        if isDemo {
            let decision = await protection.preflight()
            if decision.allowed {
                if Bundle.main.object(forInfoDictionaryKey: "CSPreviewCLIFailure") as? Bool == true {
                    let reason = "演示：目标 CLI 备份需要重新登录；账号目录和 CLI 登录尚未改变。"
                    banner = reason
                    desktopOnlyOffer = DesktopOnlySwitchOffer(source: current, target: target, reason: reason)
                    return
                }
                current = target
                cliProfile = target
                cliEmail = profiles.first { $0.name == target }?.snapshot?.email
                cliStatus = cliEmail == nil ? .needsLogin : .matched
            } else { banner = decision.message }
            return
        }
        guard let cur = try? confirmedCurrentProfile() else {
            banner = "当前档案标记缺失、不可读或无效；未修改登录和目录，请先确认原工具的档案状态。"; return
        }
        guard ProfileTransaction.validName(cur), ProfileTransaction.validName(target) else {
            banner = "档案标记或目标名称无效，未修改登录和目录。"; return
        }
        if target == cur { await openProtectedClaude(); return }
        busy = "检查网络与地区…"
        defer { busy = nil }
        do {
            try await LaunchGate.run(check: { await self.protection.preflight() }, prepare: {
                try await self.performLinkedDesktopSwitch(from: cur, to: target)
            }, launch: { try await launchProtectedDesktop(files: self.protection.files); self.protection.refreshStatus() })
            reloadList()
            busy = nil
            await refresh()
        } catch {
            banner = error.localizedDescription
            if error is CLIPreparationFailure {
                desktopOnlyOffer = DesktopOnlySwitchOffer(source: cur, target: target, reason: error.localizedDescription)
            }
            reloadList(); await refreshCLI(verify: false)
        }
    }

    private func reloadAfterOperation() { if !isDemo { reloadList() } }


}

func quitClaude() async -> Bool {
    let running = { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) }
    running().forEach { $0.terminate() }
    for _ in 0..<60 where !running().isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
    return running().isEmpty
}

@discardableResult
func launchClaude() async throws -> NSRunningApplication {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        throw err("未找到 Claude 桌面客户端，请先安装。")
    }
    return try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
}

// MARK: - Terminal (Claude Code CLI) login
//
// The CLI keeps its login in the keychain item "Claude Code-credentials" (key `claudeAiOauth`,
// next to MCP server logins under `mcpOAuth`, which stay shared) and the account details in
// ~/.claude.json `oauthAccount`. Parked logins go in our own keychain item, one per profile.
// Native Security APIs update existing entries; only the owned OAuth field is swapped.

let cliService = "Claude Code-credentials"
let switcherService = "Claude Switcher"
let cliCurrentFile = parkDir.appendingPathComponent(".cli-current")
let claudeJSON = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")

func readKeychain(service: String, account: String) throws -> [String: Any]? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
        throw err("无法读取钥匙串（状态 \(status)）；未将读取失败当作空登录。")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw err("钥匙串凭据格式异常，未修改登录。")
    }
    return json
}

func writeKeychain(service: String, account: String, json: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: json)
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account]
    var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var newItem = query; newItem[kSecValueData as String] = data
        status = SecItemAdd(newItem as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw err("无法保存钥匙串登录（状态 \(status)）。") }
}

// Code session enumeration and copying live in SwitcherCore/ThreadRepository.swift.

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var store: Store!
    var previewWindow: NSWindow?
    var previewContentHeight: CGFloat?

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            store = demoMode ? Store(demo: true) : Store()
            store.onChange = { [weak self] in self?.updateTitle() }
            store.onShowAccounts = { [weak self] in self?.showPanel() }
            popover.behavior = .transient
            popover.animates = true
            popover.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingController(rootView: MenuBarPanel(store: store))
            // Let the popover track the SwiftUI size; otherwise it's positioned at its initial
            // (too small) size and the grown content spills up past the menu bar.
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            item.button?.target = self
            item.button?.action = #selector(toggle)
            updateTitle()
            let applicationMenu = NSMenu()
            let rootItem = NSMenuItem()
            applicationMenu.addItem(rootItem)
            let commands = NSMenu()
            commands.addItem(withTitle: "打开 Claude Switcher", action: #selector(showPanel), keyEquivalent: "o").target = self
            commands.addItem(.separator())
            commands.addItem(withTitle: "退出界面（保护状态不变）", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            rootItem.submenu = commands
            ApplicationMenus.addEditMenu(to: applicationMenu)
            NSApp.mainMenu = applicationMenu
            let transferPreview = demoMode && Bundle.main.object(forInfoDictionaryKey: "CSPreviewTransfer") as? Bool == true
            if transferPreview {
                item.isVisible = false
                DispatchQueue.main.async {
                    CopyWindow.show(self.store)
                }
            }
            if demoMode && !demoPopover {
                let initialViewportHeight = max(1, (NSScreen.main?.visibleFrame.height ?? 800) * 0.75)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: initialViewportHeight),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "Claude Switcher · 演示（不操作真实账号）"
                window.isReleasedWhenClosed = false
                let contentRect = window.contentRect(forFrameRect: window.frame)
                let decorationHeight = window.frame.height - contentRect.height
                let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
                let maxContentHeight = max(1, visibleFrame.height - decorationHeight)
                window.contentViewController = NSHostingController(rootView: DemoPanel(
                    store: store,
                    initialViewportHeight: initialViewportHeight,
                    maxContentHeight: maxContentHeight
                ) { [weak self] height in
                    self?.resizePreviewWindow(to: height)
                })
                window.appearance = NSAppearance(named: .darkAqua)
                window.center()
                previewWindow = window
                if !transferPreview { DispatchQueue.main.async { self.toggle() } }
            }
            if demoPopover {
                item.isVisible = false
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 104),
                                      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
                window.title = "Claude Switcher · 弹层演示（假数据）"
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 104))
                let note = NSTextField(labelWithString: "假数据演示，不操作真实账号")
                note.font = .systemFont(ofSize: 11)
                note.textColor = .secondaryLabelColor
                note.alignment = .center
                note.frame = NSRect(x: 12, y: 66, width: 276, height: 18)
                content.addSubview(note)
                let button = NSButton(title: "打开菜单弹层", target: self, action: #selector(openPreviewPopover(_:)))
                button.bezelStyle = .rounded
                button.font = .systemFont(ofSize: 13, weight: .medium)
                button.frame = NSRect(x: 60, y: 20, width: 180, height: 32)
                content.addSubview(button)
                window.contentView = content
                window.center()
                if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
                    window.setFrameTopLeftPoint(NSPoint(x: visibleFrame.midX - window.frame.width / 2,
                                                       y: visibleFrame.maxY - 12))
                }
                previewWindow = window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async { self.openPreviewPopover(button) }
            }
        }
    }

    @MainActor func resizePreviewWindow(to contentHeight: CGFloat) {
        guard let window = previewWindow, contentHeight.isFinite, contentHeight > 0 else { return }
        if let previous = previewContentHeight, abs(previous - contentHeight) < 0.5 { return }
        previewContentHeight = contentHeight

        let oldFrame = window.frame
        let contentRect = window.contentRect(forFrameRect: oldFrame)
        let decorationHeight = oldFrame.height - contentRect.height
        let decorationWidth = oldFrame.width - contentRect.width
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? oldFrame
        let height = min(contentHeight + decorationHeight, visibleFrame.height)
        var frame = NSRect(x: oldFrame.minX, y: oldFrame.maxY - height,
                           width: 500 + decorationWidth, height: height)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        guard abs(oldFrame.height - frame.height) > 0.5
                || abs(oldFrame.width - frame.width) > 0.5
                || abs(oldFrame.minX - frame.minX) > 0.5
                || abs(oldFrame.minY - frame.minY) > 0.5 else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if store?.busy != nil || store?.protection.working == true {
                store?.banner = "操作正在进行，完成后即可退出界面。"
                return .terminateCancel
            }
            return .terminateNow
        }
    }

    @MainActor func updateTitle() {
        guard let b = item.button else { return }
        let sl = left(store.active?.snapshot?.session)
        let initial = store.current.prefix(1).uppercased()
        b.title = sl.map { " \(initial) · \(pct($0))%" } ?? " \(initial)"
        b.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Switcher")
        b.imagePosition = .imageLeading
        b.toolTip = "Claude: \(store.current)"
    }

    @objc func toggle() {
        MainActor.assumeIsolated {
            if let previewWindow {
                previewWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if popover.isShown { popover.performClose(nil); return }
            guard let b = item.button else { return }
            store.panelWillOpen()
            if let v = popover.contentViewController?.view {
                v.layoutSubtreeIfNeeded()
                popover.contentSize = v.fittingSize
            }
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func openPreviewPopover(_ sender: NSButton) {
        MainActor.assumeIsolated {
            guard demoPopover else { return }
            if popover.isShown { popover.performClose(nil) }
            store.panelWillOpen()
            if let v = popover.contentViewController?.view {
                v.layoutSubtreeIfNeeded()
                popover.contentSize = v.fittingSize
            }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func showPanel() {
        if !popover.isShown { toggle() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
}

if CommandLine.arguments.contains("--stop-protection") || CommandLine.arguments.contains("--protection-status") {
    let files = SafetyFiles(directory: support.appendingPathComponent("ClaudeSwitcher"))
    let service = GuardService(files: files, helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClaudeGuard"))
    if CommandLine.arguments.contains("--stop-protection") {
        do { try service.disable(); print("Protection stopped. Account data retained."); exit(0) }
        catch { print(error.localizedDescription); exit(1) }
    }
    let config = try? files.loadConfig()
    let report: [String: Any] = ["enabled": config?.enabled ?? false, "targetCountry": config?.expectedCountry ?? "unknown",
                               "registered": service.registered, "freshReceipt": config.map { files.loadReceipt()?.isFresh(for: $0) == true } ?? false]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    exit(0)
}

let app = NSApplication.shared
// `ClaudeSwitcher --snapshot out.png [--demo]` renders the panel to a PNG and exits.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    guard i + 1 < CommandLine.arguments.count, !CommandLine.arguments[i + 1].hasPrefix("--") else {
        print("Usage: ClaudeSwitcher --snapshot output.png --demo"); exit(2)
    }
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated {
        guard demoMode else { print("Snapshots require --demo; real accounts are not used for QA."); exit(2) }
        let store = Store(demo: true)
        Task { @MainActor in
            let r = CommandLine.arguments.contains("--copy")
                ? ImageRenderer(content: AnyView(CopyThreadsView(store: store).frame(width: 680, height: 580)))
                : ImageRenderer(content: AnyView(Panel(store: store)))
            r.scale = 2
            guard let cg = r.cgImage,
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                print("演示界面未能渲染，未生成图片。"); exit(1)
            }
            do { try data.write(to: out); exit(0) }
            catch { print("演示图片写入失败：" + error.localizedDescription); exit(1) }
        }
    }
    app.run()
}
// `ClaudeSwitcher --register-login` adds the app to Login Items and exits (used by `build.sh install`).
if CommandLine.arguments.contains("--register-login") {
    do { try SMAppService.mainApp.register(); exit(0) } catch { print("register failed: \(error)"); exit(1) }
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(demoMode ? .regular : .accessory)
app.run()
