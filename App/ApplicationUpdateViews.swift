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
            "detail.available": "下载并校验后，可手动打开安装包更新。",
            "detail.downloading": "正在下载并校验；关闭窗口会继续下载。",
            "detail.ready": "安装包已下载并通过校验，不会自动安装。",
            "detail.failedCheck": "检查更新未完成，请重试。",
            "detail.failedDownload": "下载或校验未完成，请重试。",
            "download.progress": "下载进度",
            "failure.unknown": "未提供详细原因。",
            "action.releaseNotes": "发布说明",
            "action.later": "稍后",
            "action.close": "关闭",
            "action.download": "下载",
            "action.cancelDownload": "取消下载",
            "action.retryCheck": "重新检查",
            "action.retryDownload": "重试下载",
            "action.openInstaller": "打开安装包",
            "action.showFinder": "在 Finder 中显示",
            "help.releaseNotes": "在浏览器中查看发布说明。",
            "help.close": "仅关闭更新窗口，不取消其他任务。",
            "help.download": "下载并校验所选版本；关闭窗口不会取消下载。",
            "help.cancelDownload": "取消当前下载，窗口保持打开。",
            "help.retryCheck": "重新检查是否有新版本。",
            "help.retryDownload": "重新下载并校验所选版本。",
            "help.openInstaller": "打开已下载的 DMG，并手动继续安装。",
            "help.openUnavailable": "安装包路径不可用，请重新下载。",
            "help.showFinder": "在 Finder 中显示已下载文件。"
        ],
        "en": [
            "window.title": "Software Update",
            "version.available": "New version {version} · Current {current}",
            "version.target": "Version {version}",
            "version.current": "Current version {version}",
            "detail.idle": "Check for a new version for this Mac.",
            "detail.checking": "Checking for updates…",
            "detail.current": "This version is up to date.",
            "detail.available": "Download and verify the update, then open the installer manually.",
            "detail.downloading": "Downloading and verifying. Closing this window won’t cancel the download.",
            "detail.ready": "The installer is downloaded and verified. It won’t install automatically.",
            "detail.failedCheck": "The update check didn’t finish. Try again.",
            "detail.failedDownload": "The download or verification didn’t finish. Try again.",
            "download.progress": "Download progress",
            "failure.unknown": "No details were provided.",
            "action.releaseNotes": "Release Notes",
            "action.later": "Later",
            "action.close": "Close",
            "action.download": "Download",
            "action.cancelDownload": "Cancel Download",
            "action.retryCheck": "Check Again",
            "action.retryDownload": "Retry Download",
            "action.openInstaller": "Open Installer",
            "action.showFinder": "Show in Finder",
            "help.releaseNotes": "View the release notes in your browser.",
            "help.close": "Only closes this update window. Other tasks are not cancelled.",
            "help.download": "Download and verify this version. Closing the window won’t cancel the download.",
            "help.cancelDownload": "Cancel the current download and keep this window open.",
            "help.retryCheck": "Check for a new version again.",
            "help.retryDownload": "Download and verify this version again.",
            "help.openInstaller": "Open the downloaded DMG and continue installation manually.",
            "help.openUnavailable": "The installer path is unavailable. Download the update again.",
            "help.showFinder": "Reveal the downloaded file in Finder."
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
        case .failed: return t(release == nil ? "detail.failedCheck" : "detail.failedDownload")
        }
    }

    private var failureMessage: String {
        let message = updater.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return t("failure.unknown") }
        return AppLocalization.message(message, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Switcher")
                    .font(.system(.headline, weight: .semibold))
                    .foregroundColor(.txt)
                Text(versionText)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundColor(.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusDetail)
                    .font(.callout)
                    .foregroundColor(.txt)
                    .lineSpacing(2)
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
        .padding(20)
        .frame(minWidth: 400, idealWidth: 430, maxWidth: 460, alignment: .topLeading)
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
            case .available, .downloading:
                secondaryAction(t("action.later"), help: t("help.close"), action: close)
                    .keyboardShortcut(.cancelAction)
            case .idle, .checking, .current, .ready, .failed:
                secondaryAction(t("action.close"), help: t("help.close"), action: close)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer(minLength: 0)
            switch updater.phase {
            case .available:
                primaryAction(t("action.download"), help: t("help.download"), action: downloadUpdate)
                    .disabled(release == nil)
            case .downloading:
                secondaryAction(t("action.cancelDownload"), help: t("help.cancelDownload")) {
                    updater.cancelDownload()
                }
            case .ready:
                secondaryAction(t("action.showFinder"), help: t("help.showFinder")) {
                    updater.showDownloadedFile()
                }
                .disabled(updater.downloadedURL == nil)
                primaryAction(
                    t("action.openInstaller"),
                    help: updater.downloadedURL == nil ? t("help.openUnavailable") : t("help.openInstaller")
                ) {
                    updater.openDownloadedDMG()
                }
                .disabled(updater.downloadedURL == nil)
            case .failed:
                if release == nil {
                    primaryAction(t("action.retryCheck"), help: t("help.retryCheck"), action: checkForUpdates)
                } else {
                    primaryAction(t("action.retryDownload"), help: t("help.retryDownload"), action: downloadUpdate)
                }
            case .idle, .checking, .current:
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

    private func downloadUpdate() {
        Task { await updater.download() }
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
        guard [.available, .downloading, .ready].contains(updater.phase) else { return }
        let language = AppLocalization.normalized(language)
        let window: NSWindow
        let isNewWindow: Bool
        if let existing = self.window {
            window = existing
            isNewWindow = false
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 200),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.isReleasedWhenClosed = false
            created.appearance = NSAppearance(named: .darkAqua)
            created.contentMinSize = NSSize(width: 400, height: 120)
            created.contentMaxSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
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
        window.setContentSize(NSSize(width: 430, height: fittingHeight > 0 ? fittingHeight : 200))

        if isNewWindow {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
