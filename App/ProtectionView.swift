import AppKit
import SwiftUI
import SwitcherCore

private final class ProxyModeMenuController: NSObject {
    weak var anchor: NSView?
    private var onSelect: ((ProxyMode) -> Void)?

    func show(selection: ProxyMode, autoTitle: String, onSelect: @escaping (ProxyMode) -> Void) {
        guard let anchor else { return }
        self.onSelect = onSelect
        defer { self.onSelect = nil }
        let menu = NSMenu()
        let options: [(ProxyMode, String)] = [(.shadowrocket, "Shadowrocket"), (.auto, autoTitle)]
        for (mode, title) in options {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = mode == selection ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func selectMode(_ item: NSMenuItem) {
        guard let mode = item.representedObject as? ProxyMode else { return }
        onSelect?(mode)
    }
}

private struct ProxyModeMenuAnchor: NSViewRepresentable {
    let controller: ProxyModeMenuController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        controller.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        controller.anchor = view
    }
}

struct TerminalProtectionCard: View {
    @ObservedObject var store: Store
    @ObservedObject var controller: ProtectionController
    @Environment(\.appLanguage) private var language
    let busy: Bool
    @State private var confirmProtectCurrentDesktop = false
    @State private var showSettings = false
    @State private var settingsHover = false
    @State private var guardRowHover = false
    @State private var recheckHover = false
    @State private var webCheckHover = false
    @State private var pauseHover = false
    @State private var proxyHover = false
    @State private var proxyMenuController = ProxyModeMenuController()
    @State private var saveHover = false
    @State private var guardActionHover = false
    @FocusState private var countryFocused: Bool
    /// Manual checks re-expand the result block; operation reports preserve the user's fold state.
    @State private var resultsExpanded = true
    /// Shared by the status column and the panel beneath it, so the two read as one region.
    private let panelTint = Color.white.opacity(0.025)
    private var operationLocked: Bool { busy || store.updating }
    private var diagnosticLocked: Bool { operationLocked || controller.working || controller.checking }

    init(store: Store, controller: ProtectionController, busy: Bool) {
        self.store = store
        self.controller = controller
        self.busy = busy
    }

    private func t(_ key: String, arguments: [String: String] = [:]) -> String {
        appText(key, language: language, arguments: arguments)
    }

    private func generated(_ message: String) -> String {
        if message == controller.lastDecision.message {
            return AppLocalization.decision(controller.lastDecision, language: language)
        }
        return AppLocalization.message(message, language: language)
    }

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
        func spoken(_ language: String) -> String {
            switch self {
            case .passed: return appText("protection.passed", language: language)
            case .failed: return appText("protection.failed", language: language)
            case .unknown: return appText("protection.unknownFailClosed", language: language)
            case .notRun: return appText("protection.notRun", language: language)
            case .pending: return appText("protection.pending", language: language)
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
            return [t("protection.proxy"), "TUN", t("protection.exitCountry")].map {
                NetworkItem(title: $0, value: t("common.checking"), status: .pending)
            }
        }
        let observation = controller.lastCheckReport?.observation
        let proxy: NetworkItem
        if let observation {
            if controller.lastCheckReport?.proxyMode == .auto {
                // Auto mode has no separate proxy probe; it is the TUN result, so don't count it twice.
                proxy = NetworkItem(title: t("protection.proxy"), value: t("protection.autoProxy"), status: .notRun,
                                    help: t("protection.autoProxyHelp"))
            } else if observation.proxyStatusUnconfirmed == true {
                proxy = NetworkItem(title: t("protection.proxy"), value: t("protection.unconfirmed"), status: .unknown)
            } else {
                proxy = NetworkItem(title: t("protection.proxy"),
                                    value: t(observation.proxyConnected ? "protection.connected" : "protection.disconnected"),
                                    status: observation.proxyConnected ? .passed : .failed)
            }
        } else {
            proxy = NetworkItem(title: t("protection.proxy"), value: t("protection.notRun"), status: .notRun)
        }
        let tun = observation.map {
            let unconfirmed = $0.tunStatusUnconfirmed == true
            return NetworkItem(title: "TUN",
                               value: t(unconfirmed ? "protection.unconfirmed" : $0.tunOnline ? "protection.online" : "protection.notDetected"),
                               status: unconfirmed ? .unknown : $0.tunOnline ? .passed : .failed,
                               help: t("protection.tunHelp"))
        } ?? NetworkItem(title: "TUN", value: t("protection.notRun"), status: .notRun)
        return [proxy, tun, countryItem]
    }

    private var countryItem: NetworkItem {
        guard let report = controller.lastCheckReport, let observation = report.observation else {
            return NetworkItem(title: t("protection.exitCountry"), value: t("protection.notRun"), status: .notRun)
        }
        if offerDesktopProtection {
            return NetworkItem(title: t("protection.exitCountry"), value: t("protection.desktopUnverified"), status: .unknown,
                               help: t("protection.takeoverHelp"))
        }
        if observation.routesDisagree {
            return NetworkItem(title: t("protection.exitCountry"), value: t("protection.routesDisagree"), status: .failed,
                               help: t("protection.routesHelp"))
        }
        let measuredMismatch = report.decision.reason == .countryMismatch ? report.decision.observedCountry : nil
        guard let country = observation.country ?? measuredMismatch, !country.isEmpty else {
            // A missing country can't tell whether the request was skipped or ran and was then discarded,
            // so it is "unconfirmed", never "not run".
            let help = observation.proxyConnected && observation.tunOnline
                ? t("protection.countryUnknown") : t("protection.countryUnavailable")
            return NetworkItem(title: t("protection.exitCountry"), value: t("protection.unconfirmed"), status: .unknown, help: help)
        }
        guard let target = report.targetCountry else {
            return NetworkItem(title: t("protection.exitCountry"), value: country, status: .unknown)
        }
        let matches = country.uppercased() == target.uppercased()
        return NetworkItem(title: t("protection.exitCountry"), value: matches ? country : "\(country) ≠ \(target)",
                           status: matches ? .passed : .failed)
    }

    private func failureText(_ decision: SafetyDecision) -> String {
        switch decision.reason {
        case .proxyDisconnected: return t("protection.failedProxy")
        case .tunMissing: return t("protection.failedTUN")
        case .linkUnknown: return t("protection.failedLinkUnknown")
        case .routesDisagree: return t("protection.failedRoutes")
        case .countryUnknown: return t("protection.failedCountry")
        case .countryMismatch:
            return t("protection.failedMismatch", arguments: [
                "observed": decision.observedCountry ?? t("common.unknown"),
                "expected": decision.expectedCountry ?? t("common.unknown")
            ])
        default:
            return t("protection.failedPrefix", arguments: ["message": AppLocalization.decision(decision, language: language)])
        }
    }

    private var verdict: (text: String, color: Color, icon: String) {
        guard let report = controller.lastCheckReport else { return (t("protection.neverChecked"), .sub, "minus.circle") }
        if let message = report.validationMessage {
            return (t("protection.invalidInput", arguments: ["message": generated(message)]), .warn, "exclamationmark.triangle.fill")
        }
        if report.observation == nil {
            if report.passed { return (t("protection.incomplete"), .sub, "questionmark.circle") }
            return (failureText(report.decision), .bad, "xmark.circle.fill")
        }
        if report.passed {
            return (t("protection.passedTarget", arguments: ["country": report.targetCountry ?? ""]), .good, "checkmark.circle.fill")
        }
        return (failureText(report.decision), .bad, "xmark.circle.fill")
    }

    private var isOperationReport: Bool { controller.lastCheckReport?.origin == .operation }

    /// The inputs changed after the last round, so its result no longer describes them.
    private var resultStale: Bool {
        guard let report = controller.lastCheckReport, report.validationMessage == nil,
              let target = report.targetCountry else { return false }
        let draft = controller.country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let modeChanged = report.proxyMode.map { $0 != controller.mode } ?? false
        return draft != target || modeChanged
    }

    private func freshNetworkExit(now: Date) -> (country: String, checkedAt: Date)? {
        guard !controller.checking, !controller.working, !controller.hasUnsavedChanges,
              let activeCountry = controller.activeCountry?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !activeCountry.isEmpty, let activeMode = controller.activeProxyMode else { return nil }

        func normalized(_ country: String?) -> String? {
            country?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        func fresh(_ checkedAt: Date) -> Bool {
            let age = now.timeIntervalSince(checkedAt)
            return age >= 0 && age <= SafetyConfig.maximumReceiptAge
        }

        let reportIsNewest = controller.lastCheckReport.map { report in
            controller.guardCheckedAt.map { report.checkedAt >= $0 } ?? true
        } ?? false
        if reportIsNewest, let report = controller.lastCheckReport {
            guard fresh(report.checkedAt), report.validationMessage == nil, report.passed,
                  normalized(report.targetCountry) == activeCountry, report.proxyMode == activeMode,
                  let observation = report.observation,
                  let country = normalized(observation.country), country == activeCountry else { return nil }
            return (country, report.checkedAt)
        }

        guard let checkedAt = controller.guardCheckedAt, fresh(checkedAt),
              controller.enabled, controller.guardOnline, controller.lastDecision.allowed,
              normalized(controller.lastDecision.expectedCountry) == activeCountry,
              let country = normalized(controller.lastDecision.observedCountry), country == activeCountry else { return nil }
        return (country, checkedAt)
    }

    private func networkSummary(now: Date, includeTime: Bool = true) -> String {
        guard let exit = freshNetworkExit(now: now) else {
            return t("common.target", arguments: ["country": controller.activeCountry ?? t("common.notSet")])
        }
        let exitText = t("protection.observedExit", arguments: ["country": exit.country])
        guard includeTime else { return exitText }
        let time = AppLocalization.date(exit.checkedAt, language: language, timeStyle: .short)
        return exitText + " · " + time
    }

    /// Stale completed network results lose their verdict colour; early gate failures keep their actual reason.
    private var displayVerdict: (text: String, color: Color, icon: String) {
        if resultStale, controller.lastCheckReport?.observation != nil {
            return (t("protection.stale"), .warn, "arrow.triangle.2.circlepath")
        }
        return verdict
    }

    /// One line of context only when the result could be misread against the current inputs.
    private var reportContextNote: String? {
        guard let report = controller.lastCheckReport, report.validationMessage == nil,
              let target = report.targetCountry else { return nil }
        if resultStale {
            return t(isOperationReport ? "protection.operationStaleNote" : "protection.staleNote",
                     arguments: ["country": target])
        }
        if !isOperationReport, controller.hasUnsavedChanges { return t("protection.unsavedCheck") }
        return nil
    }

    private var reportOriginHelp: String? {
        guard let report = controller.lastCheckReport else { return nil }
        switch report.origin {
        case .manualInput: return t("protection.manualInputOrigin") + "\n" + t("protection.diagnosticOnly")
        case .operation: return t("protection.operationOrigin")
        }
    }

    private func networkCell(_ item: NetworkItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.sub.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 5) {
                Circle()
                    .fill(item.status.color.opacity(item.status == .notRun ? 0.45 : 1))
                    .frame(width: 5.5, height: 5.5)
                Text(item.value)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(item.status.color)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(item.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title): \(item.value), \(item.status.spoken(language))")
    }

    private func networkMetricsStrip(scopeHelp: String) -> some View {
        let items = networkItems
        let hasReport = controller.lastCheckReport != nil
        let diagnosticLabel = controller.checking ? t("common.checking")
            : hasReport ? t("protection.recheck") : t("protection.checkOnly")
        let lastCheckTip = latestGuardCheck.map {
            t("protection.lastCheckedAt") + "：" + AppLocalization.date($0, language: language, timeStyle: .short) + "\n"
        } ?? ""
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.title) { idx, item in
                    if idx > 0 {
                        Rectangle()
                            .fill(Color.hairline)
                            .frame(width: 1)
                            .padding(.vertical, 8)
                    }
                    networkCell(item)
                }
            }
            .opacity(resultStale && !controller.checking ? 0.45 : 1)
            .help(scopeHelp)

            Rectangle()
                .fill(Color.hairline)
                .frame(width: 1)
                .padding(.vertical, 7)

            Button(action: runDiagnostic) {
                HStack(spacing: 5) {
                    if controller.checking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: hasReport ? "arrow.clockwise" : "network")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(diagnosticLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundColor(recheckHover ? .txt : .txt.opacity(0.88))
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(recheckHover ? 0.08 : 0.025))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { recheckHover = $0 }
            .animation(.easeOut(duration: 0.12), value: recheckHover)
            .disabled(diagnosticLocked)
            .opacity(diagnosticLocked ? 0.45 : 1)
            .help(lastCheckTip + t("protection.checkOnlyHelp"))
            .accessibilityLabel(diagnosticLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.bg.opacity(0.72)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline, lineWidth: 1))
    }

    // MARK: Scope

    /// The scope is spelled out only on demand (settings hover and check help), never as a standing line.
    private var desktopScopeHelp: String {
        let summary: String
        switch controller.desktopScope {
        case .subscription: summary = t("protection.subscriptionScope")
        case .api: summary = t("protection.apiScope")
        case .unknown: summary = t("protection.unknownScope")
        }
        guard let detail = controller.desktopScopeDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else { return summary }
        return summary + "\n" + generated(detail)
    }

    // MARK: Notices

    private func guardIssueReason(_ decision: SafetyDecision) -> String {
        switch decision.reason {
        case .guardUnavailable: return t("protection.guardUnavailableShort")
        case .staleReceipt: return t("protection.guardStaleShort")
        case .terminationFailed: return t("protection.terminationFailed")
        default: return failureText(decision)
        }
    }

    private var issueText: String? {
        guard let issue = controller.guardStatusIssue else { return nil }
        let reason = guardIssueReason(issue)
        if let checkedAt = controller.guardCheckedAt {
            let time = AppLocalization.date(checkedAt, language: language, timeStyle: .short)
            return t("protection.guardIssueAt", arguments: ["time": time, "reason": reason])
        }
        return t("protection.guardIssue", arguments: ["reason": reason])
    }

    private var noticeText: String? {
        if let message = controller.operationError?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return generated(message)
        }
        guard guardReason.isEmpty else { return nil }
        return issueText
    }

    private var hasNotices: Bool { noticeText != nil }

    @ViewBuilder private var notices: some View {
        if let noticeText {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).padding(.top, 1)
                Text(noticeText).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10)).foregroundColor(controller.operationError == nil ? statusColor : .bad)
            .help(noticeText)
            .accessibilityElement(children: .combine)
        }
    }

    private func toggleSettings() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showSettings.toggle()
        }
    }

    private var settingsToggleButton: some View {
        Button(action: toggleSettings) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(showSettings ? 180 : 0))
                .foregroundColor(settingsHover || guardRowHover || showSettings ? .txt : .sub)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(settingsHover && !showSettings ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { settingsHover = $0 }
        .help(t(showSettings ? "protection.collapseSettings" : "protection.expandSettings") + "\n" + desktopScopeHelp)
        .accessibilityLabel(t(showSettings ? "protection.collapseSettings" : "protection.expandSettings"))
        .accessibilityHint(t("protection.settingsHint"))
    }

    // MARK: State

    private var needsRetry: Bool {
        guard !controller.working else { return false }
        if controller.lastDecision.reason == .terminationFailed { return true }
        if controller.enabled && !controller.guardOnline { return true }
        return controller.operationError != nil && !desktopPendingTakeover
    }

    private var primaryProtectionTitle: String {
        switch controller.operationPhase {
        case .starting: return t("protection.starting")
        case .stopping: return t("protection.stopping")
        case .retrying: return t("protection.retrying")
        case .idle:
            if needsRetry { return t("protection.retry") }
            return t(controller.enabled ? "protection.pause" : "protection.enable")
        }
    }

    private func runProtectionAction() {
        guard !operationLocked, !controller.working else { return }
        if needsRetry {
            Task { await controller.retryProtection() }
        } else if controller.enabled {
            controller.disable()
        } else {
            Task { await controller.enable() }
        }
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
        if controller.desktopScope == .api || controller.desktopScope == .unknown { return .sub }
        if desktopPendingTakeover { return .warn }
        if protectedDesktop { return .good }
        if !store.claudeRunning && controller.lastDecision.allowed { return .good }
        return .warn
    }
    /// Titles describe the guard against the desktop only. "Protected" always names the desktop, so it
    /// can't be read as covering the terminal strip beside it or the account as a whole.
    private var statusTitle: String {
        if controller.desktopScope == .api { return t("protection.notApplicable") }
        if controller.working {
            switch controller.operationPhase {
            case .starting: return t("protection.starting")
            case .stopping: return t("protection.stopping")
            case .retrying: return t("protection.retrying")
            case .idle: return t("protection.updating")
            }
        }
        if !controller.enabled { return t("protection.disabled") }
        if !controller.guardOnline { return t("protection.unconfirmedStatus") }
        if controller.lastDecision.reason == .terminationFailed { return t("protection.terminationFailed") }
        if controller.desktopScope == .unknown { return t("protection.scopeUnknown") }
        if desktopPendingTakeover { return t("protection.unmanaged") }
        if !controller.lastDecision.allowed { return t("protection.blocked") }
        if !store.claudeRunning { return t("protection.ready") }
        if protectedDesktop { return t("protection.active") }
        return t("protection.unconfirmedStatus")
    }
    /// The one useful fact per state. Any actual exit is tied to a fresh check of the saved configuration;
    /// otherwise the target remains the saved one, never the draft in the settings field.
    private func statusDetail(now: Date) -> String {
        if controller.desktopScope == .api { return t("protection.subscriptionOnly") }
        let target = networkSummary(now: now, includeTime: false)
        if controller.working { return target }
        if !controller.enabled { return controller.activeCountry == nil ? "" : target }
        if !controller.guardOnline || controller.lastDecision.reason == .terminationFailed { return target }
        switch controller.desktopScope {
        case .api: return ""
        case .unknown: return t("protection.unconfirmedNotProtected")
        case .subscription: break
        }
        if !controller.lastDecision.allowed { return target }
        if !store.claudeRunning { return target + " · " + t("desktop.stopped") }
        return target
    }
    private var statusIcon: String {
        if controller.desktopScope == .api { return "shield.lefthalf.filled" }
        if controller.working { return "arrow.triangle.2.circlepath" }
        if !controller.enabled { return "shield" }
        if !controller.guardOnline { return "exclamationmark.triangle.fill" }
        if controller.desktopScope == .unknown || desktopPendingTakeover || !controller.lastDecision.allowed {
            return "shield.lefthalf.filled"
        }
        return protectedDesktop ? "checkmark.shield.fill" : "shield"
    }
    private func modeName(_ mode: ProxyMode?) -> String {
        switch mode {
        case .shadowrocket: return "Shadowrocket"
        case .auto: return t("protection.autoTUN")
        case nil: return t("common.notSet")
        }
    }
    /// Shown only while the form differs from the saved config. States the saved values only;
    /// whether the guard is actually running is shown by the status block, not here.
    private var unsavedNote: String? {
        guard controller.enabled, controller.hasUnsavedChanges else { return nil }
        guard let active = controller.activeCountry else { return t("protection.noSavedSettings") }
        return t("protection.unsavedValues", arguments: [
            "country": active, "mode": modeName(controller.activeProxyMode)
        ])
    }
    private var modeDetail: String {
        switch controller.mode {
        case .shadowrocket: return t("protection.shadowrocketDetail")
        case .auto: return t("protection.autoDetail")
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            guardLine
            if showSettings {
                settings
            } else if hasNotices {
                Rectangle().fill(Color.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) { notices }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TerminalStrip(store: store)
        }
        .onChange(of: controller.lastCheckReport?.checkedAt) { _ in
            if controller.lastCheckReport?.origin == .manualInput {
                resultsExpanded = true
            }
        }
        .onChange(of: store.updating) { updating in
            if updating { confirmProtectCurrentDesktop = false }
        }
        .confirmationDialog(t("protection.takeoverTitle"), isPresented: $confirmProtectCurrentDesktop,
                            titleVisibility: .visible) {
            Button(t("protection.takeoverAction")) {
                // Re-validate at confirm time; the desktop, network or guard may have changed meanwhile.
                guard offerDesktopProtection, !operationLocked else { return }
                Task { await controller.protectCurrentDesktop() }
            }
            Button(t("common.cancel"), role: .cancel) {}
        } message: {
            Text(t("protection.takeoverBody"))
        }
    }

    /// V5: one line shared by desktop and terminal. Normal states are quiet; a problem tints the
    /// left edge, names the reason and offers the matching next step. Details fold underneath.
    private var guardLine: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let exit = freshNetworkExit(now: context.date)?.country
            let tone: Color = statusColor == .good ? .good : statusColor == .bad ? .bad : statusColor == .warn ? .warn : .sub
            HStack(spacing: 8) {
                Button(action: toggleSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: statusIcon).font(.system(size: 12, weight: .semibold))
                            .foregroundColor(tone).frame(width: 14)
                        Text(guardTitle).font(.system(size: 12, weight: .semibold)).foregroundColor(tone)
                            .lineLimit(1).fixedSize()
                        if statusColor != .good, !guardReason.isEmpty {
                            Text(guardReason).font(.system(size: 11)).foregroundColor(.sub)
                                .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                                .padding(.leading, 2)
                        }
                        Spacer(minLength: 6)
                        if statusColor == .good, let exit {
                            exitTag(exit)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { guardRowHover = $0 }

                if let action = guardAction {
                    Button(action: action.run) {
                        HStack(spacing: 5) {
                            if controller.working { ProgressView().controlSize(.mini) }
                            Text(action.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundColor(.txt).padding(.horizontal, 10).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(guardActionHover ? 0.11 : 0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairlineStrong, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(operationLocked || controller.working)
                    .opacity(operationLocked || controller.working ? 0.5 : 1)
                    .onHover { guardActionHover = $0 }
                    .help(action.help)
                    .accessibilityLabel(action.title)
                }
                settingsToggleButton
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 36)
            .background(Color.white.opacity(guardRowHover ? 0.028 : 0))
            .background(alignment: .leading) {
                if statusColor == .warn || statusColor == .bad {
                    LinearGradient(colors: [tone.opacity(0.11), .clear], startPoint: .leading, endPoint: .trailing)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
            .animation(.easeOut(duration: 0.12), value: guardRowHover)
            .help([issueText, networkSummary(now: context.date), desktopScopeHelp].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(t("protection.statusAccessibility", arguments: ["title": guardTitle, "detail": guardReason]))
        }
    }

    /// The exit is a quiet route readout rather than a competing pill; the guard icon on the left
    /// already carries the green protected signal.
    private func exitTag(_ country: String) -> some View {
        HStack(spacing: 4) {
            Text(country)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.txt.opacity(0.74))
            Text("·")
                .font(.system(size: 10))
                .foregroundColor(.sub.opacity(0.55))
            Text("TUN")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.txt.opacity(0.74))
                .lineLimit(1)
        }
        .help(t("protection.observedExit", arguments: ["country": country]))
        .accessibilityLabel(t("protection.observedExit", arguments: ["country": country]))
    }

    private var guardTitle: String {
        if controller.desktopScope != .subscription { return statusTitle }
        if controller.working { return statusTitle }
        if offerDesktopProtection { return t("guard.unmanagedShort") }
        if !controller.enabled { return t("guard.pausedShort") }
        if !controller.guardOnline || controller.lastDecision.reason == .terminationFailed { return statusTitle }
        if !controller.lastDecision.allowed { return statusTitle }
        if !store.claudeRunning { return t("guard.readyShort") }
        return statusTitle
    }

    private var guardReason: String {
        if offerDesktopProtection { return t("protection.takeoverHint") }
        if !controller.enabled { return t("protection.disabled") }
        if controller.enabled, !controller.guardOnline { return t("protection.unconfirmedStatus") }
        if !controller.lastDecision.allowed { return failureText(controller.lastDecision) }
        return ""
    }

    private var latestGuardCheck: Date? {
        if let report = controller.lastCheckReport, report.passed { return report.checkedAt }
        return controller.guardCheckedAt
    }

    private var guardAction: (title: String, help: String, run: () -> Void)? {
        guard controller.desktopScope == .subscription, !controller.working else { return nil }
        if needsRetry { return (t("protection.retry"), t("protection.retryHelp"), { runProtectionAction() }) }
        if offerDesktopProtection { return (t("guard.takeover"), t("protection.takeoverHelp"), { confirmProtectCurrentDesktop = true }) }
        if !controller.enabled { return (t("guard.resume"), t("protection.primaryHelp"), { runProtectionAction() }) }
        if !controller.lastDecision.allowed, !(showSettings && showsDiagnosticStrip) {
            return (t("guard.recheck"), t("protection.checkOnlyHelp"), { runDiagnostic() })
        }
        return nil
    }

    private func runDiagnostic() {
        guard !diagnosticLocked else { return }
        Task { await controller.checkNow() }
    }

    private var proxyModeMenu: some View {
        Button {
            proxyMenuController.show(selection: controller.mode, autoTitle: t("protection.autoTUN")) { mode in
                controller.mode = mode
            }
            proxyHover = false
        } label: {
            HStack(spacing: 6) {
                Text(modeName(controller.mode))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.txt)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(proxyHover ? .txt : .sub)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.bg))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(proxyHover ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(ProxyModeMenuAnchor(controller: proxyMenuController))
        .fixedSize(horizontal: true, vertical: false)
        .onHover { proxyHover = $0 }
        .animation(.easeOut(duration: 0.12), value: proxyHover)
        .disabled(operationLocked || controller.working || controller.checking)
        .opacity(operationLocked || controller.working || controller.checking ? 0.5 : 1)
        .help(t("protection.saveToApply"))
        .accessibilityLabel(t("protection.proxyMode"))
        .accessibilityValue(modeName(controller.mode))
    }

    private var showsDiagnosticStrip: Bool {
        if controller.checking { return true }
        if statusColor == .bad || statusColor == .warn { return true }
        guard let report = controller.lastCheckReport else { return false }
        return report.origin == .manualInput || !report.passed || report.validationMessage != nil
    }

    private var settings: some View {
        let scopeHelp = t(controller.desktopScope == .api ? "protection.apiServiceControlHelp" : "protection.scopeExplanation")
        let showsSave = controller.enabled && controller.hasUnsavedChanges
        let showsStrip = showsDiagnosticStrip
        let hasReport = controller.lastCheckReport != nil
        let diagnosticLabel = controller.checking ? t("common.checking")
            : hasReport ? t("protection.recheck") : t("protection.checkOnly")
        return VStack(alignment: .leading, spacing: 10) {
            if hasNotices {
                VStack(alignment: .leading, spacing: 8) { notices }
            }
            if showsStrip {
                networkMetricsStrip(scopeHelp: scopeHelp)
            }
            if let validation = controller.lastCheckReport?.validationMessage, !controller.checking {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .padding(.top, 1)
                    Text(generated(validation))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10))
                .foregroundColor(.warn)
            } else if showsStrip, let note = reportContextNote, !controller.checking {
                Text(note).font(.system(size: 9.5)).foregroundColor(.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Text(t("protection.targetCountry")).font(.system(size: 10.5)).foregroundColor(.sub)
                        .lineLimit(1).fixedSize()
                    TextField("SG", text: $controller.country)
                        .textFieldStyle(.plain)
                        .focused($countryFocused)
                        .onSubmit(runDiagnostic)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center).foregroundColor(.txt)
                        .frame(width: 42, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.bg))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(countryFocused ? Color.claude.opacity(0.65) : Color.hairline, lineWidth: 1))
                        .help(t("protection.countryHelp"))
                        .accessibilityLabel(t("protection.targetCountry"))
                        .disabled(operationLocked || controller.working || controller.checking)
                }
                .fixedSize()
                HStack(spacing: 5) {
                    Text(t("protection.proxy")).font(.system(size: 10.5)).foregroundColor(.sub)
                        .lineLimit(1).fixedSize().accessibilityHidden(true)
                    proxyModeMenu
                }
                Spacer(minLength: 4)
                if !showsStrip {
                    Button(action: runDiagnostic) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(recheckHover ? .txt : .sub)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(recheckHover ? 0.09 : 0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(recheckHover ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onHover { recheckHover = $0 }
                    .animation(.easeOut(duration: 0.12), value: recheckHover)
                    .disabled(diagnosticLocked)
                    .opacity(diagnosticLocked ? 0.45 : 1)
                    .help(diagnosticLabel + " · " + t("protection.checkOnlyHelp"))
                    .accessibilityLabel(diagnosticLabel)
                }
                if showsSave {
                    Button { Task { await controller.enable() } } label: {
                        Text(t("protection.saveSettings"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.claude.opacity(saveHover ? 1 : 0.88)))
                    .onHover { saveHover = $0 }
                    .disabled(diagnosticLocked)
                    .opacity(diagnosticLocked ? 0.5 : 1)
                    .help(t("protection.saveHelp"))
                } else {
                    Link(destination: URL(string: "https://ip.net.coffee/claude/")!) {
                        HStack(spacing: 3) {
                            Text("IP / WebRTC").lineLimit(1).fixedSize()
                            Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(webCheckHover ? .txt : .sub)
                        .padding(.horizontal, 6).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(webCheckHover ? 0.06 : 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { webCheckHover = $0 }
                    .help(t("protection.webCheckHelp"))
                    .accessibilityLabel(t("protection.webCheckAccessibility"))
                }
                if controller.enabled, controller.desktopScope == .subscription {
                    Button { controller.disable() } label: {
                        Text(t("protection.pauseShort")).font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1).fixedSize()
                            .foregroundColor(.bad).padding(.horizontal, 9).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.bad.opacity(pauseHover ? 0.16 : 0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.bad.opacity(pauseHover ? 0.35 : 0.18), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { pauseHover = $0 }
                    .disabled(operationLocked || controller.working)
                    .opacity(operationLocked || controller.working ? 0.45 : 1)
                    .help(t("protection.primaryHelp"))
                }
            }
            if let unsavedNote {
                Text(unsavedNote)
                    .font(.system(size: 9.5)).foregroundColor(.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -4)
            }
        }
        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
