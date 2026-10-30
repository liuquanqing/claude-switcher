import SwiftUI
import SwitcherCore

struct TerminalProtectionCard: View {
    @ObservedObject var store: Store
    @ObservedObject var controller: ProtectionController
    @Environment(\.appLanguage) private var language
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
            if checkedMode == .auto {
                // Auto mode has no separate proxy probe; it is the TUN result, so don't count it twice.
                proxy = NetworkItem(title: t("protection.proxy"), value: t("protection.autoProxy"), status: .notRun,
                                    help: t("protection.autoProxyHelp"))
            } else {
                proxy = NetworkItem(title: t("protection.proxy"),
                                    value: t(observation.proxyConnected ? "protection.connected" : "protection.disconnected"),
                                    status: observation.proxyConnected ? .passed : .failed)
            }
        } else {
            proxy = NetworkItem(title: t("protection.proxy"), value: t("protection.notRun"), status: .notRun)
        }
        let tun = observation.map {
            NetworkItem(title: "TUN", value: t($0.tunOnline ? "protection.online" : "protection.notDetected"),
                        status: $0.tunOnline ? .passed : .failed, help: t("protection.tunHelp"))
        } ?? NetworkItem(title: "TUN", value: t("protection.notRun"), status: .notRun)
        return [proxy, tun, countryItem]
    }

    private var countryItem: NetworkItem {
        guard let report = controller.lastCheckReport, let observation = report.observation else {
            return NetworkItem(title: t("protection.exitCountry"), value: t("protection.notRun"), status: .notRun)
        }
        if observation.routesDisagree {
            return NetworkItem(title: t("protection.exitCountry"), value: t("protection.routesDisagree"), status: .failed,
                               help: t("protection.routesHelp"))
        }
        guard let country = observation.country, !country.isEmpty else {
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
        guard report.observation != nil else { return (t("protection.incomplete"), .sub, "questionmark.circle") }
        if report.passed {
            return (t("protection.passedTarget", arguments: ["country": report.targetCountry ?? ""]), .good, "checkmark.circle.fill")
        }
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
        if resultStale { return (t("protection.stale"), .warn, "arrow.triangle.2.circlepath") }
        return verdict
    }

    /// One line of context only when the result could be misread against the current inputs.
    private var reportContextNote: String? {
        guard let report = controller.lastCheckReport, report.validationMessage == nil,
              let target = report.targetCountry else { return nil }
        if resultStale { return t("protection.staleNote", arguments: ["country": target]) }
        if controller.hasUnsavedChanges { return t("protection.unsavedCheck") }
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
        .accessibilityLabel("\(item.title): \(item.value), \(item.status.spoken(language))")
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
                    Text(t("protection.checkingNetwork")).foregroundColor(.sub).lineLimit(1)
                } else {
                    Image(systemName: result.icon)
                    Text(result.text)
                        .lineLimit(resultsExpanded ? 2 : 1).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if !checking, let date = controller.lastCheckReport?.checkedAt {
                    Text(AppLocalization.date(date, language: language, timeStyle: .short))
                        .font(.system(size: 9.5, weight: .regular)).foregroundColor(.sub)
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
        .help(t(resultsExpanded ? "protection.collapseResults" : "protection.expandResults"))
        .accessibilityLabel(checking ? t("protection.checkingAccessibility") : t("protection.resultsAccessibility", arguments: ["result": result.text]))
        .accessibilityHint(t(resultsExpanded ? "protection.collapseResults" : "protection.expandResults"))
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
                            Text(t("protection.diagnosticOnly"))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Link("IP / WebRTC ↗", destination: URL(string: "https://ip.net.coffee/claude/")!)
                                .foregroundColor(.claude)
                                .help(t("protection.webCheckHelp"))
                                .accessibilityLabel(t("protection.webCheckAccessibility"))
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
            helpRow(t("protection.checkOnly"), t("protection.checkOnlyHelp"))
            helpRow(t("protection.openShow"), t("protection.openShowHelp"))
            helpRow(t("protection.unmanagedClickable"), t("protection.unmanagedHelp"))
            Divider().opacity(0.6)
            Text(t("protection.guardInterval", arguments: ["seconds": String(Int(SafetyConfig.interval))]))
            // The current desktop's scope detail lives on the column / switch hover help; not repeated here.
            Text(t("protection.scopeExplanation"))
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
        case .subscription: summary = t("protection.subscriptionScope")
        case .api: summary = t("protection.apiScope")
        case .unknown: summary = t("protection.unknownScope")
        }
        guard let detail = controller.desktopScopeDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else { return summary }
        return summary + "\n" + generated(detail)
    }

    // MARK: Notices

    /// The live problem behind an exception title (guard offline / blocked), with its next step.
    /// API / unknown scope already say everything in the column, so their generic message is skipped.
    private var issueText: String? {
        guard controller.enabled, !controller.working else { return nil }
        guard !controller.guardOnline || !controller.lastDecision.allowed else { return nil }
        if controller.guardOnline, controller.desktopScope != .subscription,
           controller.lastDecision.reason == .unsupportedMode { return nil }
        return generated(controller.status)
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
                    Text(t("protection.lastOperationFailed"))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.bad)
                    Text(generated(message))
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
                .help(t("protection.dismissNotice"))
                .accessibilityLabel(t("protection.dismissAccessibility"))
            }
            .padding(.leading, 10).padding(.trailing, 2).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.bad.opacity(0.08)))
        }
    }

    /// While the desktop can be taken over, the state and the action are one control: the tinted
    /// unmanaged-desktop pill only opens the confirmation dialog. The settings fold is a separate
    /// chevron button beside it, so the two hit areas cannot intercept each other.
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
                .help(t("protection.takeoverHelp"))
                .accessibilityLabel(t("protection.unmanagedAccessibility", arguments: ["country": controller.activeCountry ?? t("common.notSet")]))
                .accessibilityHint(t("protection.takeoverHint"))
                settingsToggleButton
            }
            Text(t("common.target", arguments: ["country": controller.activeCountry ?? t("common.notSet")]))
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
        .help(t(showSettings ? "protection.collapseSettings" : "protection.expandSettings") + "\n" + desktopScopeHelp)
        .accessibilityLabel(t(showSettings ? "protection.collapseSettings" : "protection.expandSettings"))
        .accessibilityHint(t("protection.settingsHint"))
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
                // Keep the detail inside the 164pt column without shrinking the rest of the panel.
                Text(statusDetail)
                    .font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
                    .lineLimit(1).minimumScaleFactor(0.78)
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
        .help(t(showSettings ? "protection.collapseSettings" : "protection.expandSettings") + "\n" + desktopScopeHelp)
        .accessibilityLabel(t("protection.statusAccessibility", arguments: ["title": statusTitle, "detail": statusDetail]))
        .accessibilityHint(t(showSettings ? "protection.collapseSettings" : "protection.expandSettings") + ": " + t("protection.settingsHint"))
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
        if controller.working { return t("protection.updating") }
        if !controller.enabled { return t("protection.disabled") }
        if !controller.guardOnline { return t("protection.unconfirmedStatus") }
        if controller.lastDecision.reason == .terminationFailed { return t("protection.terminationFailed") }
        if controller.desktopScope == .api { return t("protection.notApplicable") }
        if controller.desktopScope == .unknown { return t("protection.scopeUnknown") }
        if desktopPendingTakeover { return t("protection.unmanaged") }
        if !controller.lastDecision.allowed { return t("protection.blocked") }
        if !store.claudeRunning { return t("protection.ready") }
        if protectedDesktop { return t("protection.active") }
        return t("protection.unconfirmedStatus")
    }
    /// The one useful fact per state. The target shown is always the saved one the guard runs with,
    /// never the draft in the settings field.
    private var statusDetail: String {
        let target = t("common.target", arguments: ["country": controller.activeCountry ?? t("common.notSet")])
        if controller.working { return target }
        if !controller.enabled { return t(showSettings ? "protection.enableBelow" : "protection.clickToEnable") }
        if !controller.guardOnline || controller.lastDecision.reason == .terminationFailed { return target }
        switch controller.desktopScope {
        case .api:
            switch controller.apiConfiguration {
            case .magpie: return "API · " + t("api.source", arguments: ["source": "Magpie"])
            case .ccSwitch: return "API · " + t("api.source", arguments: ["source": "CC Switch"])
            case .conflict: return t("protection.apiConflict")
            case .subscription, .unknownAPI, .unconfirmed: return t("protection.apiUnconfirmed")
            }
        case .unknown: return t("protection.unconfirmedNotProtected")
        case .subscription: break
        }
        // Guard-online is implied by reaching here; when takeover is offered, `offerHeader` shows
        // its own target line instead of this one.
        if !controller.lastDecision.allowed { return target }
        if !store.claudeRunning { return target + " · " + t("desktop.stopped") }
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
        .confirmationDialog(t("protection.takeoverTitle"), isPresented: $confirmProtectCurrentDesktop,
                            titleVisibility: .visible) {
            Button(t("protection.takeoverAction")) {
                // Re-validate at confirm time; the desktop, network or guard may have changed meanwhile.
                guard offerDesktopProtection, !busy else { return }
                Task { await controller.protectCurrentDesktop() }
            }
            Button(t("common.cancel"), role: .cancel) {}
        } message: {
            Text(t("protection.takeoverBody"))
        }
        .confirmationDialog(t("protection.stopTitle"), isPresented: $confirmStop) {
            Button(t("protection.stopAction"), role: .destructive) { controller.disable() }
            Button(t("common.cancel"), role: .cancel) {}
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
                    Text(t("protection.background"))
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.txt)
                    if !controller.enabled {
                        Text(t("protection.setupPrompt"))
                            .font(.system(size: 9.5)).foregroundColor(.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle(t("protection.background"), isOn: protectionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(busy || controller.working)
                    .help(t("protection.toggleHelp", arguments: ["scope": desktopScopeHelp]))
            }
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("protection.targetCountry")).font(.system(size: 10)).foregroundColor(.sub)
                        .frame(height: 22)
                    TextField("SG", text: $controller.country)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center).foregroundColor(.txt)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.bg))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stroke, lineWidth: 1))
                        .help(t("protection.countryHelp"))
                        .accessibilityLabel(t("protection.targetCountry"))
                        .disabled(busy || controller.working || controller.checking)
                }
                .frame(width: 78, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        Text(t("protection.proxyMode")).font(.system(size: 10)).foregroundColor(.sub)
                        Button { showProxyHelp.toggle() } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 10)).foregroundColor(.sub)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(t("protection.compatibility"))
                        .accessibilityLabel(t("protection.compatibility"))
                        .popover(isPresented: $showProxyHelp, arrowEdge: .bottom) {
                            Text(modeDetail)
                                .font(.system(size: 10.5)).foregroundColor(.txt)
                                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                .frame(width: 240, alignment: .leading).padding(12)
                        }
                    }
                    .frame(height: 22)
                    Picker(t("protection.proxyMode"), selection: $controller.mode) {
                        Text("Shadowrocket").tag(ProxyMode.shadowrocket)
                        Text(t("protection.autoTUN")).tag(ProxyMode.auto)
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .disabled(busy || controller.working || controller.checking)
                    .help(t("protection.saveToApply"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if controller.enabled {
                    Button { Task { await controller.enable() } } label: {
                        Text(t(controller.hasUnsavedChanges ? "protection.saveSettings" : "common.saved"))
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
                    .help(t(controller.hasUnsavedChanges ? "protection.saveHelp" : "protection.savedHelp"))
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
                        Text(t(controller.checking ? "common.checking" : "protection.checkOnly"))
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
                .help(t("protection.checkOnlyHelp"))
                .accessibilityHint(t("protection.checkOnlyHelp"))
                if controller.lastCheckReport == nil && !controller.checking {
                    Text(t("protection.readOnly"))
                        .font(.system(size: 9.5)).foregroundColor(.sub).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { showCheckHelp.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle").font(.system(size: 10.5))
                        Text(t("protection.checkHelpButton")).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(helpHover || showCheckHelp ? .txt : .sub)
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color.stroke.opacity(helpHover || showCheckHelp ? 0.6 : 0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { helpHover = $0 }
                .help(t("protection.checkHelpSummary"))
                .accessibilityLabel(t("protection.checkHelpButton"))
                .popover(isPresented: $showCheckHelp, arrowEdge: .bottom) { checkHelpContent }
            }
            checkResults
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
