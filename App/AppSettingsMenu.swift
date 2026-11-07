import SwiftUI
import AppKit

@MainActor
struct AppSettingsMenu: View {
    @ObservedObject var store: Store
    @ObservedObject private var updater = ApplicationUpdater.shared
    @ObservedObject private var updatePresentation = ApplicationUpdatePresentation.shared
    @Environment(\.appLanguage) private var language
    @State private var hover = false

    private func t(_ key: String) -> String {
        appText(key, language: language)
    }

    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.openAtLogin },
            set: { isOn in
                if isOn != store.openAtLogin {
                    store.toggleOpenAtLogin()
                }
            }
        )
    }

    private var installationInProgress: Bool { store.updating || updater.phase == .installing }

    private var hasPendingUpdate: Bool {
        [.available, .downloading, .ready].contains(updater.phase) && updater.release != nil
    }

    private var checkTitle: String {
        if updatePresentation.isChecking { return t("settings.checkingForUpdates") }
        if hasPendingUpdate, let release = updater.release {
            return appText("settings.updateAvailable", language: language, arguments: ["version": release.version])
        }
        if updater.phase == .current {
            return appText("settings.upToDate", language: language, arguments: ["version": updater.currentVersion])
        }
        return t("settings.checkForUpdates")
    }

    private var prereleaseBinding: Binding<Bool> {
        Binding(
            get: { updater.includePrereleases },
            set: {
                guard !installationInProgress else { return }
                updater.includePrereleases = $0
            }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.appLanguage },
            set: { store.setAppLanguage($0) }
        )
    }

    var body: some View {
        Menu {
            Button(checkTitle) {
                store.checkApplicationUpdates()
            }
            .disabled(updatePresentation.isChecking)
            .help(updater.phase == .current ? t("settings.checkAgainHelp") : "")
            Toggle(t("settings.includePrereleases"), isOn: prereleaseBinding)
                .toggleStyle(.checkbox)
                .disabled(installationInProgress)
                .help(t(installationInProgress ? "settings.updateChannelLockedHelp" : "settings.includePrereleasesHelp"))
            if let notice = store.applicationUpdateNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundColor(.sub)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(notice)
            }
            Divider()
            Toggle(t("settings.openAtLogin"), isOn: openAtLoginBinding)
                .toggleStyle(.checkbox)
                .help(t("settings.openAtLoginHelp"))
            Picker(t("settings.language"), selection: languageBinding) {
                ForEach(AppLocalization.supportedLanguages) { option in
                    Text(option.selfName).tag(option.code)
                }
            }
        } label: {
            FooterIcon(icon: "gearshape", hover: hover, preservesMenuColor: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .overlay(alignment: .topTrailing) {
            if hasPendingUpdate {
                Circle()
                    .fill(Color.claude)
                    .overlay(Circle().stroke(Color.card, lineWidth: 1.5))
                    .frame(width: 7, height: 7)
                    .offset(x: -4, y: 4)
                    .allowsHitTesting(false)
            }
        }
        .help(t(hasPendingUpdate ? "settings.helpUpdateAvailable" : "settings.help"))
        .accessibilityLabel(t("settings.title"))
        .onHover { hover = $0 }
    }
}

@MainActor
extension Store {
    func checkApplicationUpdates() {
        applicationUpdateNotice = nil
        let updater = ApplicationUpdater.shared
        ApplicationUpdatePresentation.shared.check(updater: updater, language: appLanguage) { [self] feedback in
            switch feedback {
            case .current:
                break
            case .failed(let message):
                let reason = message?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = reason.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "暂时无法取得更新信息，请稍后重试或前往 GitHub。"
                self.applicationUpdateNotice = appText(
                    "settings.updateFailed",
                    language: self.appLanguage,
                    arguments: ["message": AppLocalization.message(detail, language: self.appLanguage)]
                )
            }
        }
    }
}
