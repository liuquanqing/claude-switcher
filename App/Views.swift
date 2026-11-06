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

func countdown(_ d: Date?, language: String, now: Date = Date()) -> String {
    guard let d else { return appText("format.resetUnknown", language: language) }
    let s = Int(d.timeIntervalSince(now))
    if s <= 0 { return appText("format.resetPassed", language: language) }
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 {
        return appText("format.resetHours", language: language,
                       arguments: ["hours": String(h), "minutes": String(m)])
    }
    if m > 0 { return appText("format.resetMinutes", language: language, arguments: ["minutes": String(m)]) }
    return appText("format.resetWithinMinute", language: language)
}

func weekdayTime(_ d: Date?, language: String, now: Date = Date()) -> String {
    guard let d else { return appText("format.resetUnknown", language: language) }
    if d.timeIntervalSince(now) <= 0 { return appText("format.resetPassed", language: language) }
    let f = DateFormatter()
    f.locale = AppLocalization.locale(for: language)
    f.timeZone = .current
    f.dateFormat = "E HH:mm"
    return f.string(from: d)
}

func weeklyReset(_ d: Date?, language: String, now: Date = Date()) -> String {
    guard let d else { return appText("format.resetUnknown", language: language) }
    if d.timeIntervalSince(now) <= 0 { return appText("format.resetPassed", language: language) }
    return appText("format.weeklyReset", language: language,
                   arguments: ["date": weekdayTime(d, language: language, now: now)])
}

func fullDateTime(_ d: Date?, language: String) -> String {
    guard let d else { return appText("format.timeUnknown", language: language) }
    let f = DateFormatter()
    f.locale = AppLocalization.locale(for: language)
    f.timeZone = .current
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: d)
}

func ago(_ d: Date?, language: String, now: Date = Date()) -> String {
    guard let d else { return appText("format.notUpdated", language: language) }
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return appText("format.justNow", language: language) }
    if s < 3600 { return appText("format.minutesAgo", language: language, arguments: ["count": String(s / 60)]) }
    if s < 86400 { return appText("format.hoursAgo", language: language, arguments: ["count": String(s / 3600)]) }
    return appText("format.daysAgo", language: language, arguments: ["count": String(s / 86400)])
}

/// Identity line for a profile. Loading wording only appears while a request is really running;
/// otherwise a missing identity is just "no account info".
func accountLine(_ p: Profile?, language: String) -> String? {
    guard let p else { return nil }
    if !p.signedIn { return appText("account.signedOut", language: language) }
    if let email = p.snapshot?.email { return email }
    return appText(p.usageState == .loading ? "account.readingInfo" : "account.noInfo", language: language)
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
    @Environment(\.appLanguage) private var language
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
        case (let s?, let b?) where s != b:
            return appText("account.versionBuild", language: language, arguments: ["version": s, "build": b])
        case (let s?, _): return appText("account.version", language: language, arguments: ["version": s])
        case (nil, let b?): return appText("account.version", language: language, arguments: ["version": b])
        default: return nil
        }
    }

    // MARK: Desktop control
    //
    // One control carries both the process state and the action. The action always goes through
    // `openClaude` (Store.openProtectedClaude → network gate first); the running label is never a
    // shortcut around the gate or around the takeover confirmation.

    private var running: Bool { store.claudeRunning }
    private var controlLocked: Bool { store.busy != nil || store.statusRefreshInProgress || protection.working }

    private var actionTitle: String { appText(running ? "desktop.show" : "desktop.open", language: language) }
    private var actionIcon: String { running ? "macwindow" : "play.fill" }

    private var desktopHelp: String {
        var lines: [String]
        if !running {
            lines = [appText("desktop.openHelp", language: language, arguments: ["account": store.current])]
        } else if protection.desktopScope == .subscription && !protection.desktopManaged {
            lines = [appText("desktop.unmanagedHelp", language: language)]
        } else {
            lines = [appText("desktop.showHelp", language: language)]
        }
        if protection.desktopScope != .subscription { lines.append(appText("desktop.unsupportedHelp", language: language)) }
        lines.append((store.isDemo ? appText("desktop.demo", language: language) : "")
            + appText("desktop.runningMeaning", language: language))
        return lines.joined(separator: "\n")
    }

    private var desktopControl: some View {
        Button(action: openClaude) {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(running ? Color.good : Color.sub.opacity(0.7)).frame(width: 6, height: 6)
                    Text(appText(running ? "desktop.running" : "desktop.stopped", language: language))
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
        .accessibilityLabel(appText("desktop.accessibility", language: language, arguments: [
            "state": appText(running ? "desktop.running" : "desktop.stopped", language: language),
            "action": actionTitle
        ]))
        .accessibilityHint(desktopHelp)
    }

    // MARK: API / unknown desktop
    //
    // Outside subscription mode the header names the desktop mode and the recognised source instead of
    // a saved profile's identity. The only action is the existing `store.openAPIManager()` for a
    // confirmed manager; an unconfirmed source gets no action and never falls back to opening Claude.

    private var subscriptionDesktop: Bool { protection.desktopScope == .subscription }

    private var sourceName: String? {
        guard protection.desktopScope == .api else { return nil }
        switch protection.apiConfiguration {
        case .magpie: return "Magpie"
        case .ccSwitch: return "CC Switch"
        case .subscription, .unknownAPI, .conflict, .unconfirmed: return nil
        }
    }

    private var modeTitle: String {
        appText(protection.desktopScope == .api ? "api.mode" : "api.unknownMode", language: language)
    }

    private var sourceTag: String? {
        if protection.desktopScope != .api { return appText("api.unrecognized", language: language) }
        switch protection.apiConfiguration {
        case .magpie, .ccSwitch:
            return nil
        case .conflict: return appText("api.sourceConflict", language: language)
        case .subscription, .unknownAPI, .unconfirmed: return appText("api.sourceUnconfirmed", language: language)
        }
    }

    private var modeDetail: String? {
        guard protection.desktopScope == .api else { return appText("api.unknownDetail", language: language) }
        switch protection.apiConfiguration {
        case .magpie, .ccSwitch:
            return appText("api.managedBy", language: language, arguments: ["source": sourceName ?? ""])
        case .conflict: return appText("api.conflictDetail", language: language)
        case .subscription, .unknownAPI, .unconfirmed: return appText("api.unconfirmedDetail", language: language)
        }
    }

    private var managerHelp: String {
        appText("api.managerHelp", language: language, arguments: ["source": sourceName ?? ""])
            + (store.isDemo ? "\n" + appText("desktop.demo", language: language) : "")
    }

    @ViewBuilder private var managerControl: some View {
        if let sourceName {
            Button { Task { await store.openAPIManager() } } label: {
                HStack(spacing: 5) {
                    Text(appText("api.manage", language: language))
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                    Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
                }
                .foregroundColor(.claude)
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.claude.opacity(openHover ? 0.2 : 0.1)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.claude.opacity(0.26), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(controlLocked)
            .opacity(controlLocked ? 0.45 : 1)
            .help(managerHelp)
            .onHover { openHover = $0 }
            .accessibilityLabel(appText("api.openManager", language: language, arguments: ["source": sourceName]))
            .accessibilityHint(managerHelp)
        }
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
                .accessibilityLabel(appText("account.about", language: language))
                .popover(isPresented: $showAbout, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude Switcher").font(.system(size: 12, weight: .semibold)).foregroundColor(.txt)
                        if let versionText {
                            Text(versionText).font(.system(size: 10, design: .monospaced)).foregroundColor(.sub)
                        }
                        Text(appText("account.tagline", language: language)).font(.system(size: 10.5)).foregroundColor(.sub)
                    }
                    .frame(width: 200, alignment: .leading).padding(12)
                }
            VStack(alignment: .leading, spacing: 3) {
                if subscriptionDesktop {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(store.current).font(.system(size: 19, weight: .bold)).foregroundColor(.txt).lineLimit(1)
                        Text(appText("account.current", language: language)).font(.system(size: 10, weight: .medium)).foregroundColor(.claude)
                            .fixedSize()
                    }
                    Text([accountLine(a, language: language), s?.plan]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 10.5)).foregroundColor(.sub).lineLimit(1).truncationMode(.middle)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(modeTitle).font(.system(size: 19, weight: .bold)).foregroundColor(.txt).lineLimit(1)
                        if let sourceTag {
                            Text(sourceTag).font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(sourceName == nil ? .warn : .sub)
                                .lineLimit(1).fixedSize()
                        }
                    }
                    if let modeDetail {
                        Text(modeDetail).font(.system(size: 10.5)).foregroundColor(.sub)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 8)
            if subscriptionDesktop { desktopControl } else { managerControl }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
    }
}

@MainActor
struct TerminalStrip: View {
    private struct ChoiceTarget: Identifiable {
        let profile: String
        let identity: CLIIdentity
        var id: String { profile }
    }

    @ObservedObject var store: Store
    @ObservedObject private var protection: ProtectionController
    @ObservedObject private var connection: CLIConnectionController
    @Environment(\.appLanguage) private var language
    @State private var syncHover = false
    @State private var copyHover = false
    @State private var openHover = false
    @State private var showHelp = false
    @State private var choiceTarget: ChoiceTarget?
    @State private var officialReportActive = false
    @State private var confirmSync = false
    /// Account name pinned when the dialog opens, so a background refresh or external switch
    /// can't make the user confirm X and sync Y.
    @State private var syncTarget = ""
    @State private var syncStale = false
    @State private var copyFeedback: Bool?
    @State private var copyFeedbackSequence = 0

    init(store: Store) {
        self.store = store
        self.protection = store.protection
        self.connection = store.cliConnection
    }

    private func t(_ key: String, arguments: [String: String] = [:]) -> String {
        appText(key, language: language, arguments: arguments)
    }

    private func generated(_ message: String) -> String {
        if message == protection.lastDecision.message {
            return AppLocalization.decision(protection.lastDecision, language: language)
        }
        return AppLocalization.message(message, language: language)
    }

    private var accountName: String {
        let profile = connection.expectedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty ? t("cli.currentAccount") : profile
    }

    private var subscriptionDesktop: Bool { protection.desktopScope == .subscription }
    private var showsConnectionPhase: Bool { officialReportActive && subscriptionDesktop }

    private var summaryTitle: String {
        t(subscriptionDesktop ? "cli.title" : "cli.defaultTitle")
    }

    private var summaryIcon: String { "terminal" }

    private var verifiedMatch: Bool {
        connection.phase == .matched && connection.choice != nil && connection.checkedAt != nil
    }

    private var bindingCheckedLine: String? {
        guard let checkedAt = connection.checkedAt else { return nil }
        let date = AppLocalization.date(checkedAt, language: language, dateStyle: .short, timeStyle: .short, relative: true)
        return t("cli.lastCheck", arguments: ["date": date])
    }

    private var connectionStatus: String {
        switch connection.phase {
        case .unlinked: return t("cli.unlinked")
        case .checking: return t("cli.checkingIdentity")
        case .choosing: return t("cli.choosing")
        case .opening: return t("cli.opening")
        case .waitingForLogin: return t("cli.waitingForLogin")
        case .matched:
            return verifiedMatch ? t("cli.matchShort") : t("cli.unconfirmedIdentity")
        case .mismatched: return t("cli.accountMismatch")
        case .unconfirmed: return t("cli.unconfirmedIdentity")
        case .failed: return t("cli.openFailed")
        }
    }

    private var connectionStatusColor: Color {
        switch connection.phase {
        case .mismatched, .waitingForLogin: return .warn
        case .failed: return .bad
        case .unlinked, .checking, .choosing, .opening, .matched, .unconfirmed: return .sub
        }
    }

    private var connectionDetail: String? {
        if connection.phase == .matched, !verifiedMatch {
            if let reason = connection.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                return generated(reason)
            }
            return t("cli.unconfirmedDetail")
        }
        if [.failed, .mismatched, .unconfirmed].contains(connection.phase),
           let reason = connection.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            return generated(reason)
        }
        switch connection.phase {
        case .unlinked, .checking, .opening, .choosing: return accountName
        case .matched: return verifiedMatch ? accountName : t("cli.unconfirmedDetail")
        case .waitingForLogin:
            return t("cli.waitingDetail", arguments: ["account": accountName])
        case .mismatched:
            return t("cli.mismatchDetail", arguments: ["account": accountName])
        case .unconfirmed: return t("cli.unconfirmedDetail")
        case .failed: return t("cli.openFailedDetail")
        }
    }

    private var terminalStatus: String {
        if showsConnectionPhase { return connectionStatus }
        switch connection.localRecord {
        case .sameAccount: return t("cli.recordMatch")
        case .differentAccount: return t("cli.recordDifferent")
        case .notPrepared: return t("cli.recordMissing")
        case .unconfirmed: return t("cli.recordUnconfirmed")
        }
    }

    private var terminalStatusColor: Color {
        if showsConnectionPhase { return connectionStatusColor }
        if case .differentAccount = connection.localRecord { return .warn }
        return .sub
    }

    private var terminalDetail: String {
        if showsConnectionPhase { return connectionDetail ?? accountName }
        switch connection.localRecord {
        case .sameAccount:
            return accountName
        case .differentAccount:
            return t("cli.recordDifferentDetail", arguments: ["account": accountName])
        case .notPrepared:
            return t("cli.recordMissingDetail", arguments: ["account": accountName])
        case .unconfirmed:
            return t("cli.recordUnconfirmedDetail", arguments: ["account": accountName])
        }
    }

    private var terminalBoundary: String? {
        if showsConnectionPhase {
            switch connection.phase {
            case .matched where verifiedMatch: return t("cli.officialMatchHelp")
            case .waitingForLogin, .mismatched, .unconfirmed: return t("cli.officialReportHelp")
            default: return nil
            }
        }
        switch connection.localRecord {
        case .sameAccount: return t("cli.recordMatchHelp")
        case .differentAccount: return t("cli.recordDifferentHelp")
        case .notPrepared: return t("cli.recordMissingHelp")
        case .unconfirmed: return t("cli.recordUnconfirmedHelp")
        }
    }

    private var needsPreparation: Bool {
        if showsConnectionPhase {
            return connection.phase == .choosing || connection.phase == .mismatched
        }
        switch connection.localRecord {
        case .differentAccount, .notPrepared: return true
        case .sameAccount, .unconfirmed: return false
        }
    }

    private var primaryTitle: String {
        if showsConnectionPhase {
            switch connection.phase {
            case .waitingForLogin: return t("cli.confirmLogin")
            case .failed: return t("cli.retry")
            default: break
            }
        }
        return t(needsPreparation ? "cli.prepare" : "cli.open")
    }

    private var primaryActionHelp: String {
        if showsConnectionPhase, connection.phase == .waitingForLogin { return t("cli.confirmLoginHelp") }
        return t(needsPreparation ? "cli.prepareHelp" : "cli.openHelp")
    }

    private func runPrimaryAction() {
        guard subscriptionDesktop, !controlsLocked, !connection.isBusy else { return }
        showHelp = false
        officialReportActive = true
        Task {
            if showsConnectionPhase, connection.phase == .waitingForLogin {
                await connection.confirmLogin()
            } else {
                await connection.open()
            }
        }
    }

    private var controlsLocked: Bool {
        store.updating || store.busy != nil || store.refreshing || store.statusRefreshInProgress
    }

    /// The strip keeps showing the last finished result while a background check is in flight.
    private var checking: Bool { store.cliStatusRefreshing }

    /// When the last check finished. Says nothing about whether it succeeded.
    private var checkedLine: String {
        guard let date = store.cliStatusCheckedAt else { return checking ? t("common.checking") : t("cli.notChecked") }
        let value = AppLocalization.date(date, language: language, dateStyle: .short, timeStyle: .short, relative: true)
        let when = t("cli.lastCheck", arguments: ["date": value])
        return checking ? when + t("cli.newCheck") : when
    }

    private var observedLine: String {
        guard let date = store.cliStatusCheckedAt else {
            return t(checking ? "cli.observing" : "cli.notObserved")
        }
        let value = AppLocalization.date(date, language: language, dateStyle: .short, timeStyle: .short, relative: true)
        return t("cli.lastObservation", arguments: ["date": value])
    }

    /// Sync is only offered after a check found a difference, and only against a subscription
    /// desktop; API / unknown desktops have no subscription account to sync to.
    private var canSync: Bool { store.cliStatus == .different && protection.desktopScope == .subscription }
    private var canCopyScoped: Bool { protection.desktopScope == .subscription }

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
        case .unverified: return t(standaloneVerified ? "cli.identityVerified" : "cli.unverified")
        case .matched: return t(matched ? "cli.matched" : "cli.subscriptionIdentity")
        case .different: return t(subscriptionDesktop ? "cli.different" : "cli.subscriptionIdentity")
        case .needsLogin: return t("cli.needsLogin")
        case .otherAuthentication: return t("cli.otherAuthentication")
        // A limit of this app's checker, not a terminal fault: neutral colour, no "unsupported" alarm.
        case .unsupportedStorage: return t("cli.unsupported")
        // Local report from the official CLI: not remote validation, not a desktop comparison.
        case .reported: return t("cli.reported")
        case .refreshNeeded: return t("cli.refreshNeeded")
        }
    }

    private var statusColor: Color {
        switch store.cliStatus {
        case .matched: return matched ? .good : .sub
        case .different: return subscriptionDesktop ? .warn : .sub
        case .refreshNeeded: return .warn
        case .unverified, .needsLogin, .otherAuthentication, .unsupportedStorage, .reported: return .sub
        }
    }

    private var accountDetail: String? {
        let value = [store.cliProfile, store.cliEmail].compactMap { $0 }.joined(separator: "  ·  ")
        return value.isEmpty ? nil : value
    }

    private var detail: String {
        switch store.cliStatus {
        case .unverified:
            // Identity only before any check or after an independent online verification; once a
            // check has run and failed, the failure reason must not be hidden behind the account.
            if standaloneVerified { return accountDetail ?? t("cli.noDesktopComparison") }
            if store.cliStatusCheckedAt == nil { return accountDetail ?? t("cli.notChecked") }
            if let reason = store.cliStatusDetail, !reason.isEmpty { return generated(reason) }
            return t("cli.noResult")
        case .reported: return accountDetail ?? t("cli.localReport")
        case .refreshNeeded: return t("cli.savedCredentials")
        case .matched:
            if !subscriptionDesktop { return accountDetail ?? t("cli.defaultAccountUnknown") }
            return matched ? accountDetail ?? t("cli.matchesDesktop") : t("cli.recheckDesktop")
        case .different: return accountDetail ?? t("cli.defaultAccountUnknown")
        case .needsLogin: return t("cli.noSubscription")
        case .otherAuthentication: return t("cli.mayOverride")
        case .unsupportedStorage: return accountDetail ?? t("cli.checkerUnavailable")
        }
    }

    /// One boundary sentence per state. The row already shows the result; this only says what it is
    /// not. API-mode CLI settings are independent and never covered here.
    private var detailHelp: String {
        switch store.cliStatus {
        case .reported: return t("cli.reportedHelp")
        case .refreshNeeded: return t("cli.refreshHelp")
        case .matched, .different: return t("cli.savedLoginHelp")
        case .unverified where standaloneVerified: return t("cli.standaloneHelp")
        default: return t("cli.defaultHelp")
        }
    }

    private var copyTitle: String {
        if copyFeedback == true { return t("cli.scopedCopied") }
        if copyFeedback == false { return t("cli.scopedCopyFailed") }
        return t("cli.copyScoped")
    }

    private func copyScopedCommand() {
        guard canCopyScoped, !controlsLocked, !checking else { return }
        copyFeedback = store.copyScopedCLICommand()
        copyFeedbackSequence += 1
        let sequence = copyFeedbackSequence
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard copyFeedbackSequence == sequence else { return }
            copyFeedback = nil
        }
    }

    var body: some View {
        let displayedStatus = subscriptionDesktop ? terminalStatus : status
        let displayedStatusColor = subscriptionDesktop ? terminalStatusColor : statusColor
        let displayedDetail: String? = subscriptionDesktop
            ? terminalDetail
            : (store.cliStatus == .otherAuthentication ? accountDetail : detail)
        let statusHelp = t(subscriptionDesktop ? "cli.statusHelp" : "cli.defaultStatusHelp")
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: summaryIcon).font(.system(size: 12, weight: .semibold)).foregroundColor(.claude)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.claude.opacity(0.1)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summaryTitle).font(.system(size: 12, weight: .semibold)).foregroundColor(.txt)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Button { showHelp.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(displayedStatus).font(.system(size: 10, weight: .medium))
                                .foregroundColor(displayedStatusColor).lineLimit(1).minimumScaleFactor(0.8)
                            if displayedDetail != nil {
                                Image(systemName: "info.circle").font(.system(size: 9)).foregroundColor(.sub)
                            }
                        }
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(statusHelp)
                    .accessibilityLabel("\(t("cli.statusAccessibility")): \(displayedStatus)")
                    .accessibilityHint(statusHelp)
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) { helpPopover }
                    Spacer(minLength: 4)
                }
                .frame(height: 22)
                if let displayedDetail {
                    Text(displayedDetail)
                        .font(.system(size: 10.5)).foregroundColor(.sub)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help(displayedDetail)
                } else {
                    Button { showHelp = true } label: {
                        Label(t("cli.authDetails"), systemImage: "info.circle")
                            .font(.system(size: 10.5)).foregroundColor(.sub)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(statusHelp)
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { connection.contextDidChange() }
        .onChange(of: store.current) { _ in
            officialReportActive = false
            showHelp = false
            choiceTarget = nil
            connection.contextDidChange()
        }
        .onChange(of: protection.desktopScope) { _ in
            officialReportActive = false
            showHelp = false
            choiceTarget = nil
            connection.contextDidChange()
        }
        .onChange(of: store.updating) { updating in
            if updating {
                choiceTarget = nil
                confirmSync = false
            }
        }
        .onChange(of: connection.expectedProfile) { profile in
            if let choiceTarget, profile != choiceTarget.profile {
                officialReportActive = false
                showHelp = false
                self.choiceTarget = nil
            }
        }
        .onChange(of: store.active?.snapshot?.identity) { identity in
            officialReportActive = false
            showHelp = false
            if let choiceTarget, identity != choiceTarget.identity {
                self.choiceTarget = nil
            }
            connection.contextDidChange()
        }
        .onChange(of: connection.localRecord) { _ in
            if connection.phase != .waitingForLogin, !connection.isBusy,
               connection.phase == .unconfirmed || connection.checkedAt == nil {
                officialReportActive = false
            }
        }
        .onChange(of: connection.checkedAt) { checkedAt in
            if checkedAt == nil, connection.phase != .waitingForLogin, !connection.isBusy {
                officialReportActive = false
            }
        }
        .onChange(of: connection.phase) { phase in
            switch phase {
            case .choosing:
                choiceTarget = (store.active?.snapshot?.identity).map {
                    ChoiceTarget(profile: connection.expectedProfile, identity: $0)
                }
            case .mismatched:
                choiceTarget = (store.active?.snapshot?.identity).map {
                    ChoiceTarget(profile: connection.expectedProfile, identity: $0)
                }
            case .opening, .waitingForLogin, .matched:
                choiceTarget = nil
            case .unlinked:
                officialReportActive = false
            case .checking, .unconfirmed, .failed:
                break
            }
        }
        .sheet(item: $choiceTarget) { target in
            choiceSheet(for: target)
        }
        .confirmationDialog(t("cli.syncTitle", arguments: ["account": syncTarget]), isPresented: $confirmSync,
                            titleVisibility: .visible) {
            Button(t("cli.sync")) {
                guard canSync, !controlsLocked, !checking, store.current == syncTarget else {
                    syncStale = true
                    return
                }
                let target = syncTarget
                Task { await store.moveTerminal(to: target) }
            }
            Button(t("common.cancel"), role: .cancel) {}
        } message: {
            Text(t("cli.syncBody", arguments: ["account": syncTarget]))
        }
        .alert(t("cli.staleTitle"), isPresented: $syncStale) {
            Button(t("cli.ok")) {}
        } message: {
            Text(t("cli.staleBody"))
        }
    }

    private var primaryAction: some View {
        Button(action: runPrimaryAction) {
            HStack(spacing: 5) {
                if connection.isBusy { ProgressView().controlSize(.mini) }
                Text(primaryTitle).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundColor(.claude)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.claude.opacity(openHover ? 0.16 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controlsLocked || connection.isBusy)
        .opacity(controlsLocked || connection.isBusy ? 0.55 : 1)
        .onHover { openHover = $0 }
        .help(primaryActionHelp)
        .accessibilityLabel(primaryTitle)
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            if subscriptionDesktop {
                VStack(alignment: .leading, spacing: 4) {
                    Text(terminalStatus).font(.system(size: 11, weight: .semibold)).foregroundColor(terminalStatusColor)
                    Text(terminalDetail).font(.system(size: 10.5)).foregroundColor(.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    if let terminalBoundary {
                        Text(terminalBoundary).font(.system(size: 10)).foregroundColor(.sub)
                            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                    if showsConnectionPhase, let bindingCheckedLine {
                        Text(bindingCheckedLine).font(.system(size: 10)).foregroundColor(.sub)
                    }
                }
                primaryAction
                Divider().opacity(0.5)
                DisclosureGroup(t("cli.advanced")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("cli.defaultStatus")).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.txt)
                        Text(status).font(.system(size: 10.5, weight: .medium)).foregroundColor(.sub)
                        Text(detail).font(.system(size: 10)).foregroundColor(.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(checkedLine).font(.system(size: 10)).foregroundColor(.sub)
                        Text(detailHelp).font(.system(size: 10)).foregroundColor(.sub)
                            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        if canCopyScoped {
                            Button(action: copyScopedCommand) {
                                HStack(spacing: 5) {
                                    Image(systemName: copyFeedback == true ? "checkmark" : "doc.on.doc")
                                    Text(copyTitle)
                                }
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 9).frame(height: 28)
                                .foregroundColor(copyFeedback == false ? .warn : .txt)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.sub.opacity(copyHover ? 0.14 : 0.08)))
                            }
                            .buttonStyle(.plain).disabled(controlsLocked || checking)
                            .help(t("cli.copyScopedHelp"))
                            .onHover { copyHover = $0 }
                        }
                        Button { syncTarget = store.current; confirmSync = true } label: {
                            Text(t("cli.syncTo")).font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 9).frame(height: 28)
                                .foregroundColor(canSync ? .claude : .sub)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.claude.opacity(syncHover && canSync ? 0.22 : 0.1)))
                        }
                        .buttonStyle(.plain).disabled(!canSync || controlsLocked || checking)
                        .help(t("cli.syncHelp", arguments: ["account": store.current]))
                        .onHover { syncHover = $0 }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.txt)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.system(size: 11, weight: .semibold)).foregroundColor(statusColor)
                    if store.cliStatus != .otherAuthentication {
                        Text(detail).font(.system(size: 10.5)).foregroundColor(.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(observedLine).font(.system(size: 10)).foregroundColor(.sub)
                    Text(t("cli.defaultObservationHelp")).font(.system(size: 10)).foregroundColor(.sub)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: subscriptionDesktop ? 320 : 256, alignment: .leading).padding(12)
    }

    private func choiceActionsDisabled(for target: ChoiceTarget) -> Bool {
        target.profile.isEmpty || controlsLocked || connection.isBusy
    }

    private func choiceSheet(for target: ChoiceTarget) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("cli.choiceTitle")).font(.system(size: 16, weight: .semibold)).foregroundColor(.txt)
                Text(t("cli.choiceFor", arguments: ["account": target.profile]))
                    .font(.system(size: 11)).foregroundColor(.sub).lineLimit(1)
                Text(t("cli.recommendedIsolated")).font(.system(size: 11, weight: .medium)).foregroundColor(.claude)
            }
            if connection.phase == .mismatched {
                Text(t("cli.choiceMismatch")).font(.system(size: 11)).foregroundColor(.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(t("cli.isolatedAction")) { chooseAndOpen(.isolated, target: target) }
                .buttonStyle(.borderedProminent)
                .tint(.claude)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
                .disabled(choiceActionsDisabled(for: target))
            HStack(spacing: 10) {
                Button(t("common.cancel")) { choiceTarget = nil }
                    .buttonStyle(.bordered)
                Spacer()
                Button(t("cli.defaultAction")) { chooseAndOpen(.defaultLogin, target: target) }
                    .buttonStyle(.bordered)
                    .disabled(choiceActionsDisabled(for: target))
            }
            Text(t("cli.choiceBoundary")).font(.system(size: 10.5)).foregroundColor(.sub)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 390, alignment: .leading)
        .background(Color.bg)
        .preferredColorScheme(.dark)
    }

    private func chooseAndOpen(_ choice: CLIBindingChoice, target: ChoiceTarget) {
        guard !choiceActionsDisabled(for: target) else { return }
        let profile = target.profile
        let identity = target.identity
        officialReportActive = true
        choiceTarget = nil
        Task {
            guard subscriptionDesktop, !controlsLocked, profile == connection.expectedProfile, profile == store.current,
                  let currentIdentity = store.active?.snapshot?.identity,
                  currentIdentity == identity else {
                connection.contextDidChange()
                return
            }
            await connection.choose(choice)
        }
    }
}

struct UsageMetric: View {
    let title: String
    let value: Double?
    let reset: String
    let resetHelp: String
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
            Text(reset).font(.system(size: 10)).foregroundColor(.sub)
                .lineLimit(1).minimumScaleFactor(0.82)
                .help(resetHelp)
                .accessibilityHint(resetHelp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProfileCard: View {
    let p: Profile
    let active: Bool
    /// The last-used saved profile while the desktop is API / unknown: kept in place but not marked
    /// current, since it says nothing about the identity the desktop is actually using.
    var savedOnly = false
    let busy: Bool
    let onSwitch: () -> Void
    @Environment(\.appLanguage) private var language
    @State private var hover = false

    /// Every account card shares one height, so empty / loading / failed cards sit on the same
    /// row rhythm as data cards instead of floating at their own height.
    static let height: CGFloat = 156

    private func t(_ key: String, arguments: [String: String] = [:]) -> String {
        appText(key, language: language, arguments: arguments)
    }

    private struct Placeholder {
        let icon: String
        let title: String
        var detail: String?
        var color: Color = .sub
        var spinner = false
    }

    private var placeholder: Placeholder {
        if !p.signedIn { return Placeholder(icon: "person.crop.circle.badge.plus", title: t("usage.signInAfterSwitch")) }
        switch p.usageState {
        case .loading: return Placeholder(icon: "", title: t("usage.loading"), spinner: true)
        case .blocked:
            return Placeholder(icon: "shield.lefthalf.filled", title: t("usage.notRequested"), detail: t("usage.afterProtection"))
        case .failed:
            return Placeholder(icon: "exclamationmark.triangle", title: t("usage.failed"),
                               detail: p.error.map { AppLocalization.message($0, language: language) }, color: .warn)
        case .notRequested, .cached, .loaded: return Placeholder(icon: "chart.bar", title: t("usage.noData"))
        }
    }

    @ViewBuilder private func usageFooter(_ snapshot: Snapshot, now: Date) -> some View {
        let age = ago(snapshot.fetchedAt, language: language, now: now)
        let resetReached = [snapshot.session?.resetsAt, snapshot.weekly?.resetsAt]
            .compactMap { $0 }
            .contains { $0.timeIntervalSince(now) <= 0 }
        switch p.usageState {
        case .loading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(t("usage.updating"))
            }.foregroundColor(.sub)
        case .failed:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                Text(t("usage.updated", arguments: ["age": age]))
            }
                .foregroundColor(.sub).lineLimit(1)
                .help(p.error.map { AppLocalization.message($0, language: language) } ?? t("usage.requestFailed"))
                .accessibilityLabel(t("usage.updateFailedDetail"))
        case .blocked:
            Text(t("usage.blockedCached", arguments: ["age": age])).foregroundColor(.sub)
                .help(t("usage.blockedHelp"))
        case .loaded where p.live && !resetReached:
            EmptyView()
        case .loaded where resetReached:
            Text(t("usage.updated", arguments: ["age": age])).foregroundColor(.sub)
                .help(t("usage.resetDueCachedHelp"))
        case .loaded:
            Text(t("usage.updated", arguments: ["age": age])).foregroundColor(.sub)
                .help(t("usage.cacheTimeHelp"))
        case .notRequested, .cached:
            Text(t("usage.updated", arguments: ["age": age])).foregroundColor(.sub)
                .help(t("usage.cacheTimeHelp"))
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
                        Text(accountLine(p, language: language) ?? "")
                            .font(.system(size: 10)).foregroundColor(.sub)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                // The top-right slot is shared: other cards put a switch action here, the current card
                // a plain status mark so it never reads as a second, selectable control.
                if active {
                    HStack(spacing: 4) {
                        Circle().fill(Color.claude).frame(width: 5, height: 5)
                        Text(t("common.current")).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.claude)
                    .padding(.vertical, 4)
                    .help(t("account.currentHelp"))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(t("account.current"))
                } else if savedOnly {
                    Text(t("common.saved")).font(.system(size: 10, weight: .medium)).foregroundColor(.sub)
                        .padding(.vertical, 4)
                        .help(t("account.savedHelp"))
                        .accessibilityLabel(t("account.savedAccessibility"))
                } else {
                    Button(action: onSwitch) {
                        Pill(text: t("common.switch"), fg: .txt, bg: hover ? Color(hex: 0x45423C) : .stroke)
                    }
                    .buttonStyle(.plain).disabled(busy).opacity(busy ? 0.45 : 1)
                    .help(t("account.switchHelp"))
                    .onHover { hover = $0 }
                }
            }

            if p.signedIn, let snapshot = s, snapshot.session != nil || snapshot.weekly != nil {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let sampled = fullDateTime(snapshot.fetchedAt, language: language)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            UsageMetric(title: t("usage.fiveHours"), value: left(snapshot.session),
                                        reset: countdown(snapshot.session?.resetsAt, language: language, now: context.date),
                                        resetHelp: t("usage.fiveHoursResetHelp", arguments: [
                                            "reset": fullDateTime(snapshot.session?.resetsAt, language: language),
                                            "sampled": sampled
                                        ]), prominent: true)
                            Rectangle().fill(Color.stroke.opacity(0.8)).frame(width: 1, height: 58)
                            UsageMetric(title: t("usage.weekly"), value: left(snapshot.weekly),
                                        reset: weeklyReset(snapshot.weekly?.resetsAt, language: language, now: context.date),
                                        resetHelp: t("usage.weeklyResetHelp", arguments: [
                                            "reset": fullDateTime(snapshot.weekly?.resetsAt, language: language),
                                            "sampled": sampled
                                        ]))
                        }
                        Spacer(minLength: 0)
                        usageFooter(snapshot, now: context.date).font(.system(size: 10))
                            .frame(height: 12, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            } else {
                let ph = placeholder
                Spacer(minLength: 0)
                VStack(spacing: 5) {
                    if ph.spinner {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: ph.icon).font(.system(size: 16, weight: .light)).foregroundColor(.sub)
                    }
                    Text(ph.title).font(.system(size: 10.5, weight: .regular)).foregroundColor(.sub)
                    if let detail = ph.detail {
                        Text(detail).font(.system(size: 9.5)).foregroundColor(.sub)
                            .multilineTextAlignment(.center).lineLimit(2).help(detail)
                    }
                }
                .frame(maxWidth: .infinity)
                .help(p.usageState == .blocked ? t("usage.blockedHelp") : "")
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
    @Environment(\.appLanguage) private var language
    @State private var editing = false
    @State private var name = ""
    @State private var hover = false
    @FocusState private var focused: Bool
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func t(_ key: String) -> String { appText(key, language: language) }

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
                Image(systemName: "plus").font(.system(size: 15, weight: .light))
                Text(t("account.add")).font(.system(size: 11, weight: .regular))
            }
            .foregroundColor(hover ? .txt : .sub)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(t("account.addHelp"))
    }

    private var field: some View {
        TextField(t("account.namePlaceholder"), text: $name)
            .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundColor(.txt)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: reset)
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.bg))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.stroke, lineWidth: 1))
            .onAppear { DispatchQueue.main.async { focused = true } }
            .accessibilityLabel(t("account.newName"))
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(t("common.cancel"), action: reset).buttonStyle(.plain)
                .font(.system(size: 10.5)).foregroundColor(.sub)
            Button(t("common.add"), action: commit).buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(valid ? .white : .sub)
                .padding(.horizontal, 11).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(valid ? Color.claude : Color.stroke))
                .disabled(!valid)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(t("account.new")).font(.system(size: 11, weight: .semibold)).foregroundColor(.sub)
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

struct FooterIcon: View {
    let icon: String
    let hover: Bool
    var preservesMenuColor = false

    private var color: Color { hover ? .txt : .sub }

    private var menuImage: NSImage? {
        guard preservesMenuColor else { return nil }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [NSColor(color)])
        guard let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        image.isTemplate = false
        return image
    }

    var body: some View {
        Group {
            if let image = menuImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color)
            }
        }
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.stroke : .clear))
    }
}

struct FooterButton: View {
    let icon: String; let help: String
    var accessibilityLabel: String? = nil
    var clearHoverAfterAction = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button {
            action()
            if clearHoverAfterAction { hover = false }
        } label: {
            FooterIcon(icon: icon, hover: hover)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
        .onHover { hover = $0 }
    }
}

private final class LanguageMenuController: NSObject {
    weak var anchor: NSView?
    private var onSelect: ((String) -> Void)?

    func show(selection: String, onSelect: @escaping (String) -> Void) {
        guard let anchor else { return }
        self.onSelect = onSelect
        defer { self.onSelect = nil }
        let menu = NSMenu()
        for language in AppLocalization.supportedLanguages {
            let item = NSMenuItem(title: language.selfName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.code
            item.state = language.code == selection ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func selectLanguage(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String else { return }
        onSelect?(code)
    }
}

private struct LanguageMenuAnchor: NSViewRepresentable {
    let controller: LanguageMenuController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        controller.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        controller.anchor = view
    }
}

struct LanguageMenu: View {
    @Binding var selection: String
    @State private var controller = LanguageMenuController()

    var body: some View {
        FooterButton(icon: "globe", help: "语言 / Language", clearHoverAfterAction: true) {
            controller.show(selection: selection) { selection = $0 }
        }
        .background(LanguageMenuAnchor(controller: controller))
        .accessibilityLabel("语言 / Language")
    }
}

@MainActor
struct Panel: View {
    @ObservedObject var store: Store
    @ObservedObject var protection: ProtectionController
    @Environment(\.appLanguage) private var language
    @State private var quitHover = false
    @State private var bannerDismissHover = false
    let cols = [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)]

    private func t(_ key: String, arguments: [String: String] = [:]) -> String {
        appText(key, language: language, arguments: arguments)
    }

    private func generated(_ message: String) -> String {
        if message == protection.lastDecision.message {
            return AppLocalization.decision(protection.lastDecision, language: language)
        }
        return AppLocalization.message(message, language: language)
    }

    /// Show `lastRefresh` only for a round with a successful usage snapshot, not after failure-only or empty rounds.
    private func refreshSummary(now: Date) -> (text: String, color: Color, help: String) {
        if let notice = store.usageNotice {
            let text = store.profiles.contains(where: { $0.usageState == .blocked })
                ? t("refresh.blocked") : t("refresh.noNewData")
            return (text, .sub, generated(notice))
        }
        if store.profiles.contains(where: { $0.usageState == .blocked }) {
            return (t("refresh.blocked"), .sub, t("refresh.blockedHelp"))
        }
        let failed = store.profiles.filter { $0.usageState == .failed }.count
        let hasNewData = store.profiles.contains { $0.usageState == .loaded }
        if failed > 0 {
            if hasNewData, let last = store.lastRefresh {
                let age = ago(last, language: language, now: now)
                return (t("refresh.failureSummary", arguments: ["age": age, "count": String(failed)]), .sub,
                        t("refresh.failureHelp", arguments: ["sampled": fullDateTime(last, language: language)]))
            }
            return (t("refresh.failureCached", arguments: ["count": String(failed)]), .sub,
                    t("refresh.failureCachedHelp"))
        }
        guard hasNewData, let last = store.lastRefresh else {
            if store.profiles.contains(where: { $0.snapshot != nil }) {
                return (t("refresh.noNewData"), .sub, t("refresh.noNewDataHelp"))
            }
            return (t("refresh.never"), .sub, t("refresh.neverHelp"))
        }
        let age = ago(last, language: language, now: now)
        return (t("refresh.summary", arguments: ["age": age]), .sub,
                t("refresh.summaryHelp", arguments: ["sampled": fullDateTime(last, language: language)]))
    }

    private var languageBinding: Binding<String> {
        Binding(get: { store.appLanguage }, set: { store.setAppLanguage($0) })
    }
    init(store: Store) {
        self.store = store
        self.protection = store.protection
    }

    /// Cards in their original order, then the add entry as the last grid cell.
    private var accountGrid: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(store.profiles) { p in
                let isSaved = p.name == store.current
                let subscription = protection.desktopScope == .subscription
                ProfileCard(p: p, active: isSaved && subscription, savedOnly: isSaved && !subscription,
                            busy: store.busy != nil || store.refreshing || store.statusRefreshInProgress) {
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
            TerminalProtectionCard(store: store, controller: protection, busy: store.busy != nil || store.statusRefreshInProgress)
            if let b = store.banner {
                HStack(spacing: 8) {
                    Label(t("banner.lastOperation", arguments: ["message": generated(b)]), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.warn).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.banner = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(bannerDismissHover ? .txt : .sub)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.stroke.opacity(bannerDismissHover ? 0.65 : 0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t("protection.dismissAccessibility"))
                    .accessibilityLabel(t("protection.dismissAccessibility"))
                    .onHover { bannerDismissHover = $0 }
                }
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
                            Text(t("desktopOnly.title"))
                                .font(.system(size: 10.5, weight: .medium)).foregroundColor(.txt)
                            Text(t("desktopOnly.detail", arguments: ["target": offer.target]))
                                .font(.system(size: 10)).foregroundColor(.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        Button(t("common.cancel")) { store.desktopOnlyOffer = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.sub)
                        Button(t("desktopOnly.action")) {
                            Task { await store.confirmDesktopOnlySwitch() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.claude)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.claude.opacity(0.1)))
                        .disabled(store.busy != nil || store.refreshing || store.statusRefreshInProgress)
                        .opacity(store.busy == nil && !store.refreshing && !store.statusRefreshInProgress ? 1 : 0.45)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.card.opacity(0.65)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.stroke.opacity(0.5), lineWidth: 1))
                .help(t("desktopOnly.help", arguments: [
                    "reason": generated(offer.reason), "source": offer.source, "target": offer.target
                ]))
            }
            // Capacity counts every grid cell, including the add entry: more than two rows (4 cells) scrolls.
            if store.profiles.count + 1 > 2 * cols.count {
                ScrollView { accountGrid }.frame(height: 2 * ProfileCard.height + 10 + 44) // third row peeks to signal scrolling
            } else {
                accountGrid
            }
            HStack(spacing: 7) {
                FooterButton(icon: "folder", help: t("footer.showDirectory")) {
                    if !store.isDemo { NSWorkspace.shared.activateFileViewerSelecting([parkDir]) }
                }
                Rectangle().fill(Color.stroke).frame(width: 1, height: 18)
                if let b = store.busy {
                    ProgressView().controlSize(.small)
                    Text(generated(b)).font(.system(size: 11, weight: .medium)).foregroundColor(.claude)
                        .lineLimit(1).minimumScaleFactor(0.85).layoutPriority(-1)
                } else if store.refreshing || store.statusRefreshInProgress {
                    ProgressView().controlSize(.small)
                    Text(t("common.refreshing")).font(.system(size: 11, weight: .medium)).foregroundColor(.sub)
                        .lineLimit(1).minimumScaleFactor(0.85).layoutPriority(-1)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let summary = refreshSummary(now: context.date)
                        HStack(spacing: 5) {
                            Image(systemName: store.usageNotice == nil ? "clock" : "exclamationmark.circle")
                                .font(.system(size: 10))
                            Text(summary.text).font(.system(size: 11, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .foregroundColor(summary.color)
                        .help(summary.help + "\n" + t("refresh.officialCLIHelp")
                            + (protection.desktopScope == .api ? "\n" + t("api.subscriptionUsageHelp") : ""))
                        .accessibilityElement(children: .combine)
                    }
                }
                Spacer(minLength: 4)
                if store.sessionMigrationEnabled {
                    FooterButton(icon: "doc.on.doc", help: t("footer.import")) { CopyWindow.show(store) }
                }
                FooterButton(
                    icon: "arrow.clockwise",
                    help: t("footer.refresh"),
                    accessibilityLabel: t("footer.refreshAccessibility")
                ) {
                    Task { await store.refreshAllStatuses() }
                }
                AppSettingsMenu(store: store)
                Rectangle().fill(Color.stroke).frame(width: 1, height: 18)
                Button { NSApp.terminate(nil) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "power").font(.system(size: 11, weight: .medium))
                        Text(t("footer.quit")).font(.system(size: 11, weight: .medium))
                    }
                    .fixedSize()
                    .foregroundColor(quitHover ? .txt : .sub)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color.stroke.opacity(quitHover ? 0.7 : 0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(t("footer.quitHelp"))
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
