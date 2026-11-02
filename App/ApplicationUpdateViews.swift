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
            "header.title": "软件更新",
            "header.current": "当前版本 {version}",
            "status.idle": "检查更新",
            "status.checking": "正在检查更新…",
            "status.current": "已是最新版本",
            "status.available": "发现新版本",
            "status.downloading": "正在下载更新",
            "status.ready": "安装包已校验",
            "status.failed": "更新未完成",
            "detail.idle": "检查是否有适用于此 Mac 的新版本。",
            "detail.checking": "正在获取版本信息，你可以关闭此窗口。",
            "detail.current": "Claude Switcher {version} 已是最新版本。",
            "detail.available": "版本 {version} 可供下载。",
            "detail.availableGeneric": "有新版本可供下载。",
            "detail.downloading": "正在下载版本 {version}，关闭窗口不会取消下载。",
            "detail.downloadingGeneric": "正在下载更新，关闭窗口不会取消下载。",
            "detail.ready": "版本 {version} 已下载并通过校验。",
            "detail.readyGeneric": "更新已下载并通过校验。",
            "detail.failed": "操作没有完成，请查看原因并重试。",
            "release.prerelease": "预览版",
            "download.progress": "下载进度",
            "failure.unknown": "未提供详细原因。",
            "notes.title": "发布说明 · {version}",
            "notes.empty": "暂无发布说明。",
            "notes.github": "查看 GitHub",
            "notes.githubHelp": "在浏览器中打开发布页面。",
            "prerelease.toggle": "接收预览版更新",
            "prerelease.help": "主动选择后，检查结果才会包含预览版。",
            "action.check": "检查更新",
            "action.checking": "正在检查…",
            "action.download": "下载更新",
            "action.cancel": "取消下载",
            "action.retry": "重试",
            "action.openInstaller": "打开安装包",
            "action.showFinder": "在 Finder 中显示",
            "help.check": "检查是否有新版本。",
            "help.download": "下载所选版本；关闭窗口不会取消下载。",
            "help.cancel": "取消当前下载。",
            "help.retryDownload": "重试下载所选版本。",
            "help.openInstaller": "打开已下载的 DMG，并手动继续安装。",
            "help.openUnavailable": "安装包路径不可用，请重新下载。",
            "help.showFinder": "在 Finder 中显示已下载文件。",
            "checked.last": "最近检查：{date}"
        ],
        "en": [
            "window.title": "Software Update",
            "header.title": "Software Update",
            "header.current": "Current version {version}",
            "status.idle": "Check for updates",
            "status.checking": "Checking for updates…",
            "status.current": "You’re up to date",
            "status.available": "New version available",
            "status.downloading": "Downloading update",
            "status.ready": "Installer verified",
            "status.failed": "Update not completed",
            "detail.idle": "Check for a new version for this Mac.",
            "detail.checking": "Fetching release information. You can close this window.",
            "detail.current": "Claude Switcher {version} is up to date.",
            "detail.available": "Version {version} is ready to download.",
            "detail.availableGeneric": "A new version is ready to download.",
            "detail.downloading": "Downloading version {version}. Closing this window won’t cancel the download.",
            "detail.downloadingGeneric": "Downloading the update. Closing this window won’t cancel the download.",
            "detail.ready": "Version {version} has been downloaded and verified.",
            "detail.readyGeneric": "The update has been downloaded and verified.",
            "detail.failed": "The operation didn’t finish. Review the message and try again.",
            "release.prerelease": "Prerelease",
            "download.progress": "Download progress",
            "failure.unknown": "No details were provided.",
            "notes.title": "Release notes · {version}",
            "notes.empty": "No release notes provided.",
            "notes.github": "View on GitHub",
            "notes.githubHelp": "Open the release page in your browser.",
            "prerelease.toggle": "Receive prerelease updates",
            "prerelease.help": "Opt in to include prereleases when checking for updates.",
            "action.check": "Check for Updates",
            "action.checking": "Checking…",
            "action.download": "Download Update",
            "action.cancel": "Cancel Download",
            "action.retry": "Try Again",
            "action.openInstaller": "Open Installer",
            "action.showFinder": "Show in Finder",
            "help.check": "Check whether a new version is available.",
            "help.download": "Download the selected version. Closing this window won’t cancel the download.",
            "help.cancel": "Cancel the current download.",
            "help.retryDownload": "Try downloading the selected version again.",
            "help.openInstaller": "Open the downloaded DMG and continue installation manually.",
            "help.openUnavailable": "The installer path is unavailable. Download the update again.",
            "help.showFinder": "Reveal the downloaded file in Finder.",
            "checked.last": "Last checked: {date}"
        ]
    ]
}

@MainActor
struct ApplicationUpdateView: View {
    @ObservedObject var updater: ApplicationUpdater
    let language: String

    private func t(_ key: String, arguments: [String: String] = [:]) -> String {
        ApplicationUpdateLocalization.text(key, language: language, arguments: arguments)
    }

    private var release: AppRelease? { updater.release }

    private var showsRelease: Bool {
        guard release != nil else { return false }
        switch updater.phase {
        case .available, .downloading, .ready, .failed: return true
        case .idle, .checking, .current: return false
        }
    }

    private var downloadProgress: Double {
        min(max(updater.progress, 0), 1)
    }

    private var downloadProgressText: String {
        "\(Int((downloadProgress * 100).rounded()))%"
    }

    private var statusTitle: String {
        switch updater.phase {
        case .idle: return t("status.idle")
        case .checking: return t("status.checking")
        case .current: return t("status.current")
        case .available: return t("status.available")
        case .downloading: return t("status.downloading")
        case .ready: return t("status.ready")
        case .failed: return t("status.failed")
        }
    }

    private var statusDetail: String {
        switch updater.phase {
        case .idle:
            return t("detail.idle")
        case .checking:
            return t("detail.checking")
        case .current:
            return t("detail.current", arguments: ["version": updater.currentVersion])
        case .available:
            guard let version = release?.version else { return t("detail.availableGeneric") }
            return t("detail.available", arguments: ["version": version])
        case .downloading:
            guard let version = release?.version else { return t("detail.downloadingGeneric") }
            return t("detail.downloading", arguments: ["version": version])
        case .ready:
            guard let version = release?.version else { return t("detail.readyGeneric") }
            return t("detail.ready", arguments: ["version": version])
        case .failed:
            return t("detail.failed")
        }
    }

    private var statusColor: Color {
        switch updater.phase {
        case .idle: return .sub
        case .checking, .available, .downloading: return .claude
        case .current, .ready: return .good
        case .failed: return .warn
        }
    }

    private var statusIcon: String {
        switch updater.phase {
        case .idle, .checking: return "arrow.clockwise.circle"
        case .current, .ready: return "checkmark.circle.fill"
        case .available, .downloading: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var failureMessage: String {
        let message = updater.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return t("failure.unknown") }
        return AppLocalization.message(message, language: language)
    }

    private var prereleaseBinding: Binding<Bool> {
        Binding(get: { updater.includePrereleases }, set: { updater.includePrereleases = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusCard
            if showsRelease, let release {
                releaseNotesCard(release)
            }
            Spacer(minLength: 0)
            prereleaseOption
            Rectangle()
                .fill(Color.stroke.opacity(0.75))
                .frame(height: 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                actions
                if let lastCheckedAt = updater.lastCheckedAt {
                    let date = AppLocalization.date(lastCheckedAt, language: language,
                                                    dateStyle: .short, timeStyle: .short, relative: true)
                    Text(t("checked.last", arguments: ["date": date]))
                        .font(.caption)
                        .foregroundColor(.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 540, maxWidth: .infinity,
               minHeight: 520, idealHeight: 600, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.bg)
        .preferredColorScheme(.dark)
        .environment(\.appLanguage, AppLocalization.normalized(language))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.claude.opacity(0.12))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.claude.opacity(0.28), lineWidth: 1)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundColor(.claude)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(t("header.title"))
                    .font(.system(.title3, weight: .semibold))
                    .foregroundColor(.txt)
                    .fixedSize(horizontal: false, vertical: true)
                Text(t("header.current", arguments: ["version": updater.currentVersion]))
                    .font(.footnote)
                    .foregroundColor(.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if updater.phase == .checking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.claude)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(.title3, weight: .medium))
                            .foregroundColor(statusColor)
                    }
                }
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(statusTitle)
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.txt)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(statusDetail)
                        .font(.callout)
                        .foregroundColor(.sub)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsRelease, release?.prerelease == true {
                        Text(t("release.prerelease"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.warn)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.warn.opacity(0.12)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsRelease, let release {
                let asset = "\(release.asset.name) · \(ByteCountFormatter.string(fromByteCount: release.asset.size, countStyle: .file))"
                Label(asset, systemImage: "doc")
                    .font(.caption)
                    .foregroundColor(.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(asset)
                    .accessibilityLabel(asset)
            }

            if updater.phase == .downloading {
                VStack(spacing: 5) {
                    ProgressView(value: downloadProgress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.claude)
                        .accessibilityLabel(t("download.progress"))
                        .accessibilityValue(downloadProgressText)
                    Text(downloadProgressText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.sub)
                        .frame(maxWidth: .infinity, alignment: .trailing)
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.stroke.opacity(0.6), lineWidth: 1))
    }

    private func releaseNotesCard(_ release: AppRelease) -> some View {
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    releaseNotesTitle(release)
                    Spacer(minLength: 8)
                    releasePageButton
                }
                VStack(alignment: .leading, spacing: 7) {
                    releaseNotesTitle(release)
                    releasePageButton
                }
            }
            ScrollView(.vertical) {
                Text(verbatim: notes.isEmpty ? t("notes.empty") : notes)
                    .font(.callout)
                    .foregroundColor(.sub)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.trailing, 4)
            }
            .frame(minHeight: 64, maxHeight: 170)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.card.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.stroke.opacity(0.45), lineWidth: 1))
    }

    private func releaseNotesTitle(_ release: AppRelease) -> some View {
        Text(t("notes.title", arguments: ["version": release.version]))
            .font(.system(.callout, weight: .semibold))
            .foregroundColor(.txt)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var releasePageButton: some View {
        Button { updater.openReleasePage() } label: {
            Label(t("notes.github"), systemImage: "arrow.up.right")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.claude)
        .help(t("notes.githubHelp"))
        .accessibilityLabel(t("notes.github"))
        .accessibilityHint(t("notes.githubHelp"))
    }

    private var prereleaseOption: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: prereleaseBinding) {
                Text(t("prerelease.toggle"))
                    .font(.callout)
                    .foregroundColor(.txt)
            }
            .toggleStyle(.checkbox)
            .help(t("prerelease.help"))
            .accessibilityLabel(t("prerelease.toggle"))
            .accessibilityHint(t("prerelease.help"))
            Text(t("prerelease.help"))
                .font(.caption)
                .foregroundColor(.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionItems }
            VStack(alignment: .trailing, spacing: 10) { actionItems }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var actionItems: some View {
        switch updater.phase {
        case .idle, .current:
            primaryAction(t("action.check"), systemImage: "arrow.clockwise", help: t("help.check")) {
                checkForUpdates()
            }
        case .checking:
            primaryAction(t("action.checking"), systemImage: "arrow.clockwise", help: t("detail.checking")) {}
                .disabled(true)
        case .available:
            primaryAction(t("action.download"), systemImage: "arrow.down", help: t("help.download")) {
                downloadUpdate()
            }
            .disabled(release == nil)
        case .downloading:
            secondaryAction(t("action.cancel"), systemImage: "xmark", help: t("help.cancel")) {
                updater.cancelDownload()
            }
        case .ready:
            secondaryAction(t("action.showFinder"), systemImage: "folder", help: t("help.showFinder")) {
                updater.showDownloadedFile()
            }
            .disabled(updater.downloadedURL == nil)
            primaryAction(t("action.openInstaller"), systemImage: "arrow.right.circle",
                          help: updater.downloadedURL == nil ? t("help.openUnavailable") : t("help.openInstaller")) {
                updater.openDownloadedDMG()
            }
            .disabled(updater.downloadedURL == nil)
        case .failed:
            if release == nil {
                primaryAction(t("action.retry"), systemImage: "arrow.clockwise", help: t("help.check")) {
                    checkForUpdates()
                }
            } else {
                primaryAction(t("action.retry"), systemImage: "arrow.clockwise", help: t("help.retryDownload")) {
                    downloadUpdate()
                }
            }
        }
    }

    private func primaryAction(_ title: String, systemImage: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundColor(.bg)
        }
        .buttonStyle(.borderedProminent)
        .tint(.claude)
        .controlSize(.regular)
        .font(.system(.callout, weight: .semibold))
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }

    private func secondaryAction(_ title: String, systemImage: String, help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
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
    private var hasOpened = false

    private override init() {
        super.init()
    }

    func show(updater: ApplicationUpdater, language: String) {
        let language = AppLocalization.normalized(language)
        let window: NSWindow
        let isNewWindow: Bool
        if let existing = self.window {
            window = existing
            isNewWindow = false
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.isReleasedWhenClosed = false
            created.appearance = NSAppearance(named: .darkAqua)
            created.contentMinSize = NSSize(width: 500, height: 520)
            created.tabbingMode = .disallowed
            self.window = created
            window = created
            isNewWindow = true
        }

        window.title = ApplicationUpdateLocalization.text("window.title", language: language)
        window.contentViewController = NSHostingController(
            rootView: ApplicationUpdateView(updater: updater, language: language)
        )

        if ![.checking, .downloading, .ready].contains(updater.phase) {
            Task { await updater.check(manual: true) }
        }

        if isNewWindow {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
