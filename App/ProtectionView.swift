import SwiftUI
import SwitcherCore

struct TerminalProtectionCard: View {
    @ObservedObject var store: Store
    @ObservedObject var controller: ProtectionController
    @Environment(\.appLanguage) private var language
    let busy: Bool
    @State private var confirmProtectCurrentDesktop = false
    @State private var showSettings = false
    @State private var showCheckHelp = false
    @State private var showProxyHelp = false
    @State private var helpHover = false
    @State private var takeoverHover = false
    @State private var settingsHover = false
    @State private var protectionHover = false
    /// Manual checks re-expand the result block; operation reports preserve the user's fold state.
    @State private var resultsExpanded = true
    @State private var resultsHover = false
    /// Shared by the status column and the panel beneath it, so the two read as one region.
    private let panelTint = Color.white.opacity(0.03)
    private var operationLocked: Bool { busy || store.updating }

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
        case .manualInput: return t("protection.manualInputOrigin")
        case .operation: return t("protection.operationOrigin")
        }
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
        let resultText = isOperationReport ? result.text : t("protection.lastDiagnostic", arguments: ["result": result.text])
        let checking = controller.checking
        return Button { resultsExpanded.toggle() } label: {
            HStack(spacing: 6) {
                if checking {
                    ProgressView().controlSize(.small)
                    Text(t("protection.checkingNetwork")).foregroundColor(.sub).lineLimit(1)
                } else {
                    Image(systemName: result.icon)
                    Text(resultText)
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
        .help(reportOriginHelp.map {
            $0 + "\n" + t(resultsExpanded ? "protection.collapseResults" : "protection.expandResults")
        } ?? t(resultsExpanded ? "protection.collapseResults" : "protection.expandResults"))
        .accessibilityLabel(checking ? t("protection.checkingAccessibility") : t("protection.resultsAccessibility", arguments: ["result": resultText]))
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
                            if isOperationReport {
                                Spacer(minLength: 0)
                            } else {
                                Text(t("protection.diagnosticOnly"))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
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

    private var protectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if protectedSummaryCountry != nil {
                ViewThatFits(in: .horizontal) {
                    protectedSummary(inlineCountry: true)
                    protectedSummary(inlineCountry: false)
                }
            } else {
                statusRow
                Group {
                    Text(statusDetail.isEmpty ? " " : statusDetail)
                        .font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .padding(.leading, 26)
                        .opacity(statusDetail.isEmpty ? 0 : 1)
                        .accessibilityHidden(statusDetail.isEmpty)
                }
            }
            if controller.desktopScope == .subscription && needsRetry {
                protectionAction
            }
        }
        .padding(.horizontal, 2).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityLabel(t("protection.statusAccessibility", arguments: ["title": statusTitle, "detail": statusDetail]))
    }

    private var statusRow: some View {
        HStack(spacing: 4) {
            if offerDesktopProtection {
                Button { confirmProtectCurrentDesktop = true } label: {
                    HStack(spacing: 4) {
                        statusContent
                        Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(statusColor.opacity(takeoverHover ? 0.2 : 0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(operationLocked || controller.working)
                .onHover { takeoverHover = $0 }
                .help(t("protection.takeoverHelp"))
                .accessibilityLabel(t("protection.unmanagedAccessibility", arguments: ["country": controller.activeCountry ?? t("common.notSet")]))
                .accessibilityHint(t("protection.takeoverHint"))
            } else {
                statusContent.padding(.horizontal, 6)
            }
            settingsToggleButton
        }
    }

    private func protectedSummary(inlineCountry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if inlineCountry {
                    inlineStatusContent
                } else {
                    statusContent.padding(.horizontal, 6)
                }
                settingsToggleButton
            }
            if !inlineCountry, let country = protectedSummaryCountry {
                Text(country)
                    .font(.system(size: 9.5, weight: .medium)).foregroundColor(.sub)
                    .lineLimit(1).padding(.leading, 32)
            }
        }
    }

    private var inlineStatusContent: some View {
        HStack(spacing: 5) {
            Image(systemName: statusIcon).font(.system(size: 11, weight: .semibold))
                .frame(width: 14, height: 14)
            if let country = protectedSummaryCountry {
                (Text(statusTitle) + Text(" · " + country).foregroundColor(.sub))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .foregroundColor(statusColor)
    }

    private var protectedSummaryCountry: String? {
        guard controller.enabled, !controller.working, protectedDesktop,
              let country = controller.activeCountry?.trimmingCharacters(in: .whitespacesAndNewlines),
              !country.isEmpty else { return nil }
        return country
    }

    private var statusContent: some View {
        HStack(spacing: 5) {
            Image(systemName: statusIcon).font(.system(size: 11, weight: .semibold))
                .frame(width: 14, height: 14)
            Text(statusTitle).font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.72)
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .foregroundColor(statusColor)
    }

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

    private var protectionActionIsSecondary: Bool {
        controller.enabled && !needsRetry && controller.operationPhase == .idle
    }

    private var protectionAction: some View {
        Button(action: runProtectionAction) {
            HStack(spacing: 5) {
                if controller.working { ProgressView().controlSize(.mini) }
                Text(primaryProtectionTitle).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, protectionActionIsSecondary ? 9 : 12)
            .frame(maxWidth: protectionActionIsSecondary ? nil : .infinity)
            .frame(height: 28)
            .foregroundColor(protectionActionIsSecondary ? .sub : .white)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(protectionActionIsSecondary
                      ? Color.sub.opacity(protectionHover ? 0.14 : 0.07)
                      : Color.claude.opacity(protectionHover ? 0.9 : 0.78)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(Color.stroke.opacity(protectionActionIsSecondary ? 1 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(operationLocked || controller.working)
        .opacity(operationLocked || controller.working ? 0.55 : 1)
        .onHover { protectionHover = $0 }
        .help(t(needsRetry ? "protection.retryHelp" : "protection.primaryHelp"))
        .accessibilityLabel(primaryProtectionTitle)
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
    /// The one useful fact per state. The target shown is always the saved one the guard runs with,
    /// never the draft in the settings field.
    private var statusDetail: String {
        if controller.desktopScope == .api { return t("protection.subscriptionOnly") }
        let target = t("common.target", arguments: ["country": controller.activeCountry ?? t("common.notSet")])
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
        if controller.desktopScope == .api { return "shield" }
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
            HStack(spacing: 0) {
                TerminalStrip(store: store)
                    // The divider closes off the summary side only, so the tinted column runs
                    // straight into the panel below it like a tab.
                    .overlay(alignment: .bottom) {
                        if showSettings { Rectangle().fill(Color.stroke.opacity(0.4)).frame(height: 1) }
                    }
                Rectangle().fill(Color.stroke.opacity(0.55)).frame(width: 1)
                    .padding(.vertical, showSettings ? 0 : 10)
                VStack(alignment: .leading, spacing: 0) {
                    protectionHeader
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

    private var settings: some View {
        // Controls only: status, scope and target are the column's job and are not repeated here.
        VStack(alignment: .leading, spacing: 10) {
            if hasNotices {
                VStack(alignment: .leading, spacing: 8) { notices }
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
                        .disabled(operationLocked || controller.working || controller.checking)
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
                    .disabled(operationLocked || controller.working || controller.checking)
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
                    .disabled(operationLocked || controller.working || !controller.hasUnsavedChanges)
                    .opacity(operationLocked || controller.working ? 0.55 : 1)
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
                .buttonStyle(.plain).disabled(operationLocked || controller.working || controller.checking)
                .opacity(operationLocked || controller.working || controller.checking ? 0.55 : 1)
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
            if controller.desktopScope == .api {
                Text(t("protection.apiServiceControlHelp"))
                    .font(.system(size: 9.5)).foregroundColor(.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.5)
            HStack {
                Spacer(minLength: 0)
                protectionAction
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
