import AppKit
import SwiftUI
import CommonCrypto
import ServiceManagement
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

// MARK: - Data

struct Window: Codable { var used: Double; var resetsAt: Date? }

struct Snapshot: Codable {
    var email: String?
    var name: String?
    var plan: String?
    var session: Window?
    var weekly: Window?
    var weeklyOpus: Window?
    var extraEnabled: Bool?
    var fetchedAt: Date
}

struct Profile: Identifiable {
    var id: String { name }
    let name: String
    var snapshot: Snapshot?
    var signedIn: Bool
    var error: String?
    var live: Bool { error == nil && snapshot.map { Date().timeIntervalSince($0.fetchedAt) < 600 } == true }
}

func currentProfile() -> String {
    (try? String(contentsOf: currentFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultProfiles[0]
}

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

var cachedSafeKey: Data?

func safeStorageKey() throws -> Data {
    if let k = cachedSafeKey { return k }
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "Claude Safe Storage",
                            kSecReturnData as String: true]
    var out: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    guard st == errSecSuccess, let pw = out as? Data else {
        throw err("Keychain access denied (\(st)). Allow access to \"Claude Safe Storage\".")
    }
    var key = Data(count: 16)
    let salt = Array("saltysalt".utf8)
    let rc = key.withUnsafeMutableBytes { kp in
        pw.withUnsafeBytes { pp in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pp.baseAddress!.assumingMemoryBound(to: Int8.self), pw.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 kp.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
        }
    }
    guard rc == kCCSuccess else { throw err("Key derivation failed") }
    cachedSafeKey = key
    return key
}

func decrypt(_ b64: String) throws -> Data {
    guard let raw = Data(base64Encoded: b64), raw.prefix(3) == Data("v10".utf8) else { throw err("Unknown token format") }
    let body = raw.dropFirst(3)
    let key = try safeStorageKey()
    let iv = [UInt8](repeating: 0x20, count: 16)
    var out = Data(count: body.count + 16)
    var moved = 0
    let outCap = out.count
    let rc = out.withUnsafeMutableBytes { op in
        body.withUnsafeBytes { bp in
            key.withUnsafeBytes { kp in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        kp.baseAddress, 16, iv, bp.baseAddress, body.count, op.baseAddress, outCap, &moved)
            }
        }
    }
    guard rc == kCCSuccess else { throw err("Token decrypt failed") }
    return out.prefix(moved)
}

func err(_ s: String) -> NSError { NSError(domain: "switcher", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

/// Best non-expired token with user:profile scope from a profile's config.json, or nil if signed out.
func token(for dir: URL) throws -> String? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
          let cfg = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let enc = cfg["oauth:tokenCacheV2"] as? String else { return nil }
    let dict = try JSONSerialization.jsonObject(with: try decrypt(enc)) as? [String: [String: Any]] ?? [:]
    let now = Date().timeIntervalSince1970 * 1000
    return dict.filter { $0.key.contains("user:profile") }
        .compactMap { _, v -> (String, Double)? in
            guard let t = v["token"] as? String, let e = v["expiresAt"] as? Double, e > now else { return nil }
            return (t, e)
        }
        .max { $0.1 < $1.1 }?.0
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
    guard code == 200 else { throw err(code == 401 ? "Session expired — switch to it to re-auth" : "API error \(code)") }
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
    let acct = prof["account"] as? [String: Any]
    let org = prof["organization"] as? [String: Any]
    return Snapshot(email: acct?["email"] as? String,
                    name: org?["name"] as? String,
                    plan: planName(org),
                    session: window(usage["five_hour"]),
                    weekly: window(usage["seven_day"]),
                    weeklyOpus: window(usage["seven_day_opus"]),
                    extraEnabled: (usage["extra_usage"] as? [String: Any])?["is_enabled"] as? Bool,
                    fetchedAt: Date())
}

func loadCache(_ name: String) -> Snapshot? {
    guard let d = try? Data(contentsOf: cacheDir.appendingPathComponent("\(name).json")) else { return nil }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    return try? dec.decode(Snapshot.self, from: d)
}

func saveCache(_ name: String, _ s: Snapshot) {
    try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    try? enc.encode(s).write(to: cacheDir.appendingPathComponent("\(name).json"), options: .atomic)
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
    var onChange: (() -> Void)?
    let protection: ProtectionController
    let isDemo: Bool
    var sessionMigrationEnabled: Bool { false }
    @Published private(set) var refreshing = false

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
        lastRefresh = now
        profiles = [
            Profile(name: "Personal", snapshot: snap("ada@lovelace.dev", "Max 5x", 28, 3.3, 61, 50), signedIn: true),
            Profile(name: "Business", snapshot: snap("ada@analytical.co", "Team", 86, 1.2, 74, 98), signedIn: true),
            Profile(name: "Side Project", snapshot: nil, signedIn: false),
        ]
        // Model an externally changed terminal login only when explicitly requested for QA.
        if CommandLine.arguments.contains("--demo-cli-mismatch") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewCLIMismatch") as? Bool == true {
            cliProfile = "Business"
            cliEmail = profiles.first { $0.name == cliProfile }?.snapshot?.email
        }
        if CommandLine.arguments.contains("--demo-many") || Bundle.main.object(forInfoDictionaryKey: "CSPreviewManyAccounts") as? Bool == true {
            profiles += (1...9).map { number in
                Profile(name: "演示账号 \(number) · 较长名称", snapshot: snap("demo\(number)@example.com", "Max", 20, 2, 35, 72), signedIn: true)
            }
        }
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
        openAtLogin = SMAppService.mainApp.status == .enabled
        try? fm.createDirectory(at: parkDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: currentFile.path) {
            try? defaultProfiles[0].write(to: currentFile, atomically: true, encoding: .utf8)
        }
        for p in defaultProfiles where p != currentProfile() {
            try? fm.createDirectory(at: parkDir.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        reloadList()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in await self.refresh() } }
        Task { await refresh() }
    }

    var active: Profile? { profiles.first { $0.name == current } }

    func reloadList() {
        guard !isDemo else { return }
        current = currentProfile()
        claudeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        profiles = allProfileNames().map { n in
            profiles.first { $0.name == n } ?? Profile(name: n, snapshot: loadCache(n), signedIn: true)
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
            refreshCLI(); onChange?()
            return
        }
        banner = nil
        await withTaskGroup(of: (String, Result<Snapshot, Error>?).self) { g in
            for p in profiles {
                let dir = profileDir(p.name)
                g.addTask {
                    do {
                        guard let tok = try token(for: dir) else { return (p.name, nil) }
                        return (p.name, .success(try await fetchSnapshot(tok)))
                    } catch { return (p.name, .failure(error)) }
                }
            }
            for await (name, res) in g {
                guard let i = profiles.firstIndex(where: { $0.name == name }) else { continue }
                switch res {
                case nil: profiles[i].signedIn = false; profiles[i].error = nil
                case .success(let s)?: profiles[i].snapshot = s; profiles[i].signedIn = true; profiles[i].error = nil; saveCache(name, s)
                case .failure(let e)?:
                    profiles[i].error = e.localizedDescription
                    if e.localizedDescription.contains("Keychain") { banner = e.localizedDescription }
                }
            }
        }
        refreshCLI()
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
            do { try await launchClaude() } catch { banner = "打开 Claude 失败：" + error.localizedDescription }
        }
        reloadAfterOperation()
    }

    func switchTo(_ target: String) async {
        guard busy == nil else { return }
        banner = nil
        guard !refreshing else { banner = "用量正在刷新，请稍后切换账号。"; return }
        if isDemo {
            let decision = await protection.preflight()
            if decision.allowed {
                current = target
                cliProfile = target
                cliEmail = profiles.first { $0.name == target }?.snapshot?.email
            } else { banner = decision.message }
            return
        }
        let cur = currentProfile()
        if target == cur { await openProtectedClaude(); return }
        busy = "检查网络与地区…"
        defer { busy = nil }
        do {
            try await LaunchGate.run(check: { await self.protection.preflight() }, prepare: {
                self.busy = "正在退出 Claude…"
                guard await quitClaude() else { throw err("Claude didn't quit. Close it manually, then switch again.") }
                self.busy = "正在切换到 \(target)…"
                try ProfileTransaction(live: liveDir, parked: parkDir, marker: currentFile)
                    .switchProfile(from: cur, to: target)
                self.reloadList()
                self.busy = "正在同步终端 OAuth…"
                do { try await self.switchCLI(to: target) }
                catch { throw err("桌面账号已切换，终端同步失败；Claude 未重新打开：" + error.localizedDescription) }
            }, launch: { try await launchClaude() })
            reloadList()
            busy = nil
            await refresh()
        } catch { banner = error.localizedDescription; reloadList() }
    }

    private func reloadAfterOperation() { if !isDemo { reloadList() } }

    func refreshCLI() {
        guard !isDemo else { return }
        cliEmail = liveOauthAccount()?["emailAddress"] as? String
        if let saved = (try? String(contentsOf: cliCurrentFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            cliProfile = saved
        } else {
            // First run: work out which profile the terminal is on from its email.
            cliProfile = profiles.first { $0.snapshot?.email != nil && $0.snapshot?.email == cliEmail }?.name
                ?? (cliEmail == nil ? current : nil)
            if let p = cliProfile { try? p.write(to: cliCurrentFile, atomically: true, encoding: .utf8) }
        }
    }

    /// Parks the terminal's Claude login under its current profile and restores `target`'s
    /// (or logs the terminal out if `target` has none yet, so `claude /login` can set it up).
    func switchCLI(to target: String) async throws {
        refreshCLI()
        guard let cur = cliProfile else {
            throw err("Couldn't tell which profile the terminal is logged in as (\(cliEmail ?? "unknown")).")
        }
        var live = try readLiveCLICreds() ?? [:]
        let previousToken = live
        let previousIdentity = try Data(contentsOf: claudeJSON)
        guard (try JSONSerialization.jsonObject(with: previousIdentity)) is [String: Any] else {
            throw err("~/.claude.json 格式异常，未修改登录。")
        }
        if let oauth = live["claudeAiOauth"] as? [String: Any] {
            // A still-running `claude` can re-save its old login after a switch. Make sure the
            // login we're about to park really belongs to `cur` before filing it there.
            guard let expected = profiles.first(where: { $0.name == cur })?.snapshot?.email,
                  let tok = oauth["accessToken"] as? String, !tok.isEmpty else {
                throw err("无法确认终端登录归属，未备份或覆盖凭据；请先刷新账号信息。")
            }
            let response = try await getJSON("profile", tok)
            let actual = (response["account"] as? [String: Any])?["email"] as? String
            try AccountIdentity.requireMatch(expected: expected, observed: actual)
            if cur == target { return }
            var parked: [String: Any] = ["claudeAiOauth": oauth]
            parked["oauthAccount"] = liveOauthAccount()
            try writeKeychain(service: switcherService, account: "cli-\(cur)", json: parked)
        }
        let restore = try readKeychain(service: switcherService, account: "cli-\(target)")
        for payload in [live, restore ?? [:]] {
            if let oauth = payload["claudeAiOauth"], !(oauth is [String: Any]) {
                throw err("终端 OAuth 凭据格式不兼容，未修改登录。")
            }
        }
        if let identity = restore?["oauthAccount"], !(identity is [String: Any]) {
            throw err("目标终端身份格式不兼容，未修改登录。")
        }
        live["claudeAiOauth"] = restore?["claudeAiOauth"]
        var tokenUpdated = false
        do {
            try writeKeychain(service: cliService, account: NSUserName(), json: live)
            tokenUpdated = true
            try setLiveOauthAccount(restore?["oauthAccount"] as? [String: Any])
            try target.write(to: cliCurrentFile, atomically: true, encoding: .utf8)
        } catch {
            guard tokenUpdated else { throw error }
            do {
                try writeKeychain(service: cliService, account: NSUserName(), json: previousToken)
                try previousIdentity.write(to: claudeJSON, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeJSON.path)
            } catch { throw err("终端登录写入及还原失败，请保留现有数据并停止切换。") }
            throw err("终端同步失败，已还原原登录。")
        }
        refreshCLI()
    }

    func moveTerminal(to target: String) async {
        if isDemo {
            banner = nil; cliProfile = target
            cliEmail = profiles.first { $0.name == target }?.snapshot?.email
            return
        }
        guard busy == nil else { return }
        banner = nil
        guard !refreshing else { banner = "用量正在刷新，请稍后同步终端登录。"; return }
        busy = "检查网络与地区…"
        defer { busy = nil }
        let decision = await protection.preflight()
        guard decision.allowed else { banner = decision.message; return }
        busy = "正在同步终端 OAuth…"
        do { try await switchCLI(to: target) } catch { banner = "Terminal not switched: \(error.localizedDescription)" }
    }

    func scanThreads(_ profile: String) throws -> ThreadScan {
        if isDemo {
            let examples = ["项目规划", "接口调试", "多组织会话"]
            return ThreadScan(threads: examples.enumerated().map { index, title in
                ThreadInfo(file: URL(fileURLWithPath: "/demo/local_\(index).json"), title: title,
                           cwd: "/demo/projects/Example", lastActivity: Date().addingTimeInterval(Double(-index * 300)),
                           archived: false, account: "demo-account", organization: index == 2 ? "workspace-b" : "workspace-a")
            }, unreadable: 0)
        }
        return try ThreadRepository().scan(profileDir(profile))
    }

    func threadDestinations(_ profile: String) throws -> [ThreadDestination] {
        if isDemo {
            return ["workspace-a", "workspace-b"].map {
                ThreadDestination(directory: URL(fileURLWithPath: "/demo/" + $0), account: "demo-account", organization: $0)
            }
        }
        return try ThreadRepository().destinations(profileDir(profile))
    }

    func copyThreads(_ threads: [ThreadInfo], to target: String, destinationID: String) async -> String {
        guard sessionMigrationEnabled else { return "会话迁移暂未启用：待核对既有订阅/API 迁移脚本。" }
        guard busy == nil else { return "Busy, try again in a moment." }
        if isDemo { return "Copied \(threads.count) demo threads; no files changed." }
        busy = "检查复制目标…"
        defer { busy = nil; reloadList() }
        do {
            // Resolve again at execution time; the account may have changed since selection.
            guard let destination = try threadDestinations(target).first(where: { $0.id == destinationID }) else {
                throw err("目标组织已变化，请重新选择。")
            }
            let restart = target == currentProfile()
                && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            if restart {
                let decision = await protection.preflight()
                guard decision.allowed else { throw err(decision.message) }
                guard await quitClaude() else { throw err("Claude didn't quit. Close it manually and try again.") }
            }
            busy = "Copying \(threads.count) threads…"
            let result = try ThreadRepository().copy(threads, to: destination)
            if restart {
                let decision = await protection.preflight()
                guard decision.allowed else {
                    return "Copied \(result.copied); Claude 未重新打开：" + decision.message
                }
                try await launchClaude()
            }
            return "Copied \(result.copied) threads to \(target) (\(result.skipped) already there)."
        } catch { return "Copy failed: " + error.localizedDescription }
    }

}

func quitClaude() async -> Bool {
    let running = { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) }
    running().forEach { $0.terminate() }
    for _ in 0..<60 where !running().isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
    return running().isEmpty
}

func launchClaude() async throws {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        throw err("未找到 Claude 桌面客户端，请先安装。")
    }
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
}

// MARK: - Terminal (Claude Code CLI) login
//
// The CLI keeps its login in the keychain item "Claude Code-credentials" (key `claudeAiOauth`,
// next to MCP server logins under `mcpOAuth`, which stay shared) and the account details in
// ~/.claude.json `oauthAccount`. Parked logins go in our own keychain item, one per profile.
// Everything goes through /usr/bin/security, which is how the CLI itself reads the item.

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

func readLiveCLICreds() throws -> [String: Any]? { try readKeychain(service: cliService, account: NSUserName()) }

func liveOauthAccount() -> [String: Any]? {
    ((try? Data(contentsOf: claudeJSON)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["oauthAccount"] as? [String: Any]
}

func setLiveOauthAccount(_ acct: [String: Any]?) throws {
    guard var j = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeJSON)) as? [String: Any] else {
        throw err("Couldn't read ~/.claude.json")
    }
    j["oauthAccount"] = acct
    try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .withoutEscapingSlashes])
        .write(to: claudeJSON, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeJSON.path)
}

// Code session enumeration and copying live in SwitcherCore/ThreadRepository.swift.

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var store: Store!
    var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            store = demoMode ? Store(demo: true) : Store()
            store.onChange = { [weak self] in self?.updateTitle() }
            popover.behavior = .transient
            popover.animates = true
            popover.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingController(rootView: Panel(store: store))
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
            NSApp.mainMenu = applicationMenu
            if demoMode {
                let height = min(CGFloat(860), (NSScreen.main?.visibleFrame.height ?? 900) - 60)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: height),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "Claude Switcher · 演示（不操作真实账号）"
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: ScrollView { Panel(store: store) }
                    .frame(width: 500, height: height).background(Color.bg))
                window.appearance = NSAppearance(named: .darkAqua)
                window.center()
                previewWindow = window
                DispatchQueue.main.async { self.toggle() }
            }
        }
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
            Task { await store.refresh() }
            if let v = popover.contentViewController?.view {
                v.layoutSubtreeIfNeeded()
                popover.contentSize = v.fittingSize
            }
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
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
