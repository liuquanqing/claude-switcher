import AppKit
import SwiftUI
import SwitcherCore

private enum ApplicationUpdateLocalization {
    static func text(_ key: String, language: String, arguments: [String: String] = [:]) -> String {
        let language = AppLocalization.normalized(language)
        var result = values[language]?[key] ?? values[AppLocalization.defaultLanguage]?[key] ?? key
        for (name, value) in arguments {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }

    private static let values: [String: [String: String]] = [
        "zh": [
            "window.title": "软件更新",
            "version.available": "新版本 {version} · 当前 {current}",
            "version.target": "版本 {version}",
            "version.current": "当前版本 {version}",
            "detail.idle": "可检查是否有适用于此 Mac 的新版本。",
            "detail.checking": "正在检查更新…",
            "detail.current": "当前版本已是最新版。",
            "detail.available": "下载并安装后自动重启切换器。",
            "detail.downloading": "正在下载…",
            "detail.ready": "已下载，可以安装并重启。",
            "detail.installing": "正在安装并重启…",
            "detail.failedCheck": "检查更新未完成，请重试。",
            "detail.failedDownload": "下载或校验未完成，请重试。",
            "detail.failedInstall": "更新未完成，可重试安装。",
            "download.progress": "下载进度",
            "failure.unknown": "未提供详细原因。",
            "action.releaseNotes": "发布说明",
            "action.later": "稍后",
            "action.cancelUpdate": "取消更新",
            "action.hideProgress": "稍后",
            "action.close": "关闭",
            "action.retryCheck": "重新检查",
            "action.updateAndRelaunch": "更新并重启",
            "action.retryUpdate": "重试更新",
            "action.openInstaller": "手动打开安装包",
            "help.releaseNotes": "在浏览器中查看发布说明。",
            "help.close": "仅关闭更新窗口，不取消已提交的任务。",
            "help.cancelUpdate": "取消下载，不进入安装。",
            "help.hideProgress": "仅隐藏窗口，安装会继续。",
            "help.retryCheck": "重新检查是否有新版本。",
            "help.updateAndRelaunch": "下载、校验并安装此版本，然后自动重启。",
            "help.retryUpdate": "从仍可复用的阶段继续更新。",
            "help.openInstaller": "仅手动打开已下载的 DMG，不会自动安装或重启。",
            "help.openUnavailable": "安装包路径不可用，请重新下载。"
        ],
        "en": [
            "window.title": "Software Update",
            "version.available": "New version {version} · Current {current}",
            "version.target": "Version {version}",
            "version.current": "Current version {version}",
            "detail.idle": "Check for a new version for this Mac.",
            "detail.checking": "Checking for updates…",
            "detail.current": "This version is up to date.",
            "detail.available": "The switcher relaunches after installation.",
            "detail.downloading": "Downloading…",
            "detail.ready": "Downloaded. Ready to install and relaunch.",
            "detail.installing": "Installing and relaunching…",
            "detail.failedCheck": "The update check didn’t finish. Try again.",
            "detail.failedDownload": "The download or verification didn’t finish. Try again.",
            "detail.failedInstall": "The update didn’t finish. You can retry installation.",
            "download.progress": "Download progress",
            "failure.unknown": "No details were provided.",
            "action.releaseNotes": "Release Notes",
            "action.later": "Later",
            "action.cancelUpdate": "Cancel Update",
            "action.hideProgress": "Later",
            "action.close": "Close",
            "action.retryCheck": "Check Again",
            "action.updateAndRelaunch": "Update and Relaunch",
            "action.retryUpdate": "Retry Update",
            "action.openInstaller": "Open Installer Manually",
            "help.releaseNotes": "View the release notes in your browser.",
            "help.close": "Only closes this update window. Submitted tasks are not cancelled.",
            "help.cancelUpdate": "Cancel the download before installation.",
            "help.hideProgress": "Only hides the window. Installation continues.",
            "help.retryCheck": "Check for a new version again.",
            "help.updateAndRelaunch": "Download, verify, and install this version, then relaunch automatically.",
            "help.retryUpdate": "Continue from the latest reusable update stage.",
            "help.openInstaller": "Only opens the downloaded DMG. It does not install or relaunch automatically.",
            "help.openUnavailable": "The installer path is unavailable. Download the update again."
        ]
    ]
}

@MainActor
struct ApplicationUpdateView: View {
    @ObservedObject var updater: ApplicationUpdater
    let language: String
    let close: () -> Void

    private func t(_ key: String, arguments: [String: String] = [:]) -> String {
        ApplicationUpdateLocalization.text(key, language: language, arguments: arguments)
    }

    private var release: AppRelease? { updater.release }

    private var downloadProgress: Double {
        min(max(updater.progress, 0), 1)
    }

    private var downloadProgressText: String {
        "\(Int((downloadProgress * 100).rounded()))%"
    }

    private var versionText: String {
        if updater.phase == .available, let release {
            return t("version.available", arguments: [
                "version": release.version,
                "current": updater.currentVersion
            ])
        }
        if let release {
            return t("version.target", arguments: ["version": release.version])
        }
        return t("version.current", arguments: ["version": updater.currentVersion])
    }

    private var statusDetail: String {
        switch updater.phase {
        case .idle: return t("detail.idle")
        case .checking: return t("detail.checking")
        case .current: return t("detail.current")
        case .available: return t("detail.available")
        case .downloading: return t("detail.downloading")
        case .ready: return t("detail.ready")
        case .installing: return t("detail.installing")
        case .failed:
            if release == nil { return t("detail.failedCheck") }
            return t(updater.canRetryInstall ? "detail.failedInstall" : "detail.failedDownload")
        }
    }

    private var failureMessage: String {
        let message = updater.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return t("failure.unknown") }
        return AppLocalization.message(message, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(versionText)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundColor(.txt)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusDetail)
                    .font(.callout)
                    .foregroundColor(.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updater.phase == .available, release != nil {
                releaseNotesLink
            }

            if updater.phase == .downloading {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(t("download.progress"))
                        Spacer()
                        Text(downloadProgressText).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundColor(.sub)
                    ProgressView(value: downloadProgress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .accessibilityLabel(t("download.progress"))
                        .accessibilityValue(downloadProgressText)
                }
            }

            if updater.phase == .ready {
                Button(action: updater.openDownloadedDMG) {
                    Label(t("action.openInstaller"), systemImage: "arrow.up.right")
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(updater.downloadedURL == nil)
                .help(updater.downloadedURL == nil ? t("help.openUnavailable") : t("help.openInstaller"))
            }

            if updater.phase == .failed {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundColor(.warn)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            actions
        }
        .padding(18)
        .frame(minWidth: 360, idealWidth: 400, maxWidth: 440, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.bg)
        .preferredColorScheme(.dark)
        .environment(\.appLanguage, AppLocalization.normalized(language))
    }

    private var releaseNotesLink: some View {
        Button(action: updater.openReleasePage) {
            Label(t("action.releaseNotes"), systemImage: "arrow.up.right")
        }
        .buttonStyle(.link)
        .font(.callout)
        .help(t("help.releaseNotes"))
        .accessibilityLabel(t("action.releaseNotes"))
        .accessibilityHint(t("help.releaseNotes"))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .available, .ready:
                secondaryAction(t("action.later"), help: t("help.close"), action: close)
                    .keyboardShortcut(.cancelAction)
            case .downloading:
                secondaryAction(t("action.cancelUpdate"), help: t("help.cancelUpdate")) {
                    updater.cancelDownload()
                }
                .keyboardShortcut(.cancelAction)
            case .installing:
                secondaryAction(t("action.hideProgress"), help: t("help.hideProgress"), action: close)
                    .keyboardShortcut(.cancelAction)
            case .idle, .checking, .current, .failed:
                secondaryAction(t("action.close"), help: t("help.close"), action: close)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer(minLength: 0)
            switch updater.phase {
            case .available, .ready:
                primaryAction(t("action.updateAndRelaunch"), help: t("help.updateAndRelaunch"), action: updateAndRelaunch)
                    .disabled(release == nil || (updater.phase == .ready && !updater.canInstall))
            case .failed:
                if release == nil {
                    primaryAction(t("action.retryCheck"), help: t("help.retryCheck"), action: checkForUpdates)
                } else {
                    primaryAction(t("action.retryUpdate"), help: t("help.retryUpdate"), action: updateAndRelaunch)
                        .disabled(updater.canRetryInstall && !updater.canInstall)
                }
            case .installing:
                ProgressView().controlSize(.small)
            case .idle, .checking, .current, .downloading:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func primaryAction(_ title: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .tint(.accentColor)
            .controlSize(.regular)
            .font(.system(.callout, weight: .semibold))
            .help(help)
            .accessibilityLabel(title)
            .accessibilityHint(help)
    }

    private func secondaryAction(_ title: String, help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .font(.system(.callout, weight: .medium))
            .help(help)
            .accessibilityLabel(title)
            .accessibilityHint(help)
    }

    private func checkForUpdates() {
        Task { await updater.check(manual: true) }
    }

    private func updateAndRelaunch() {
        Task {
            if updater.phase == .available || (updater.phase == .failed && !updater.canRetryInstall) {
                await updater.download()
            }
            guard updater.canInstall else { return }
            await updater.installAndRelaunch()
        }
    }
}

@MainActor
final class ApplicationUpdateWindowController: NSObject {
    static let shared = ApplicationUpdateWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show(updater: ApplicationUpdater, language: String) {
        guard [.available, .downloading, .ready, .installing].contains(updater.phase)
                || (updater.phase == .failed && updater.release != nil) else { return }
        let language = AppLocalization.normalized(language)
        let window: NSWindow
        let isNewWindow: Bool
        if let existing = self.window {
            window = existing
            isNewWindow = false
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.isReleasedWhenClosed = false
            created.appearance = NSAppearance(named: .darkAqua)
            created.contentMinSize = NSSize(width: 360, height: 110)
            created.contentMaxSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
            created.level = .normal
            created.tabbingMode = .disallowed
            self.window = created
            window = created
            isNewWindow = true
        }

        window.title = ApplicationUpdateLocalization.text("window.title", language: language)
        let hostingController = NSHostingController(
            rootView: ApplicationUpdateView(updater: updater, language: language) { [weak self] in
                self?.window?.close()
            }
        )
        window.contentViewController = hostingController
        let fittingHeight = hostingController.view.fittingSize.height
        window.setContentSize(NSSize(width: 400, height: fittingHeight > 0 ? fittingHeight : 140))

        if isNewWindow {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
