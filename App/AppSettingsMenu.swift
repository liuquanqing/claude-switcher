import SwiftUI

@MainActor
struct AppSettingsMenu: View {
    @ObservedObject var store: Store
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

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.appLanguage },
            set: { store.setAppLanguage($0) }
        )
    }

    var body: some View {
        Menu {
            Button(t("settings.checkForUpdates")) {
                ApplicationUpdateWindowController.shared.show(
                    updater: ApplicationUpdater.shared,
                    language: store.appLanguage
                )
            }
            Divider()
            Toggle(t("settings.openAtLogin"), isOn: openAtLoginBinding)
                .help(t("settings.openAtLoginHelp"))
            Picker(t("settings.language"), selection: languageBinding) {
                ForEach(AppLocalization.supportedLanguages) { option in
                    Text(option.selfName).tag(option.code)
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(hover ? .txt : .sub)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.stroke : .clear))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .help(t("settings.help"))
        .accessibilityLabel(t("settings.title"))
        .onHover { hover = $0 }
    }
}
