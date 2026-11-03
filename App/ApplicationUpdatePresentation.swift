import AppKit
import Combine

/// A menu check is an action, not navigation. Keep successful no-op checks and
/// failures in the panel; only an actionable update needs the download window.
@MainActor
final class ApplicationUpdatePresentation: ObservableObject {
    enum Feedback { case current; case failed(String?) }
    static let shared = ApplicationUpdatePresentation()

    @Published private(set) var isChecking = false
    var onWillPresent: (() -> Void)?
    private var observation: AnyCancellable?
    private let present: @MainActor (ApplicationUpdater, String) -> Void

    init(present: @escaping @MainActor (ApplicationUpdater, String) -> Void = {
        ApplicationUpdateWindowController.shared.show(updater: $0, language: $1)
    }) {
        self.present = present
    }

    func check(updater: ApplicationUpdater, language: String,
               feedback: @escaping (Feedback) -> Void) {
        guard !isChecking else { return }
        if updater.phase == .downloading || updater.phase == .ready {
            show(updater, language: language)
            return
        }

        isChecking = true
        let channel = updater.includePrereleases
        // Subscribe before starting. If the daily check is already in flight,
        // share its result rather than opening a checking window or fetching twice.
        // @Published emits before storing its new value. Present on the next
        // main-queue turn so the window sees the completed phase and release.
        observation = updater.$phase.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak updater] phase in
            guard let self, let updater, phase != .checking else { return }
            self.observation = nil
            self.isChecking = false
            switch phase {
            case .available, .downloading, .ready:
                self.show(updater, language: language)
            case .current:
                feedback(.current)
            case .failed:
                feedback(.failed(updater.message))
            case .idle:
                // A joined daily check can fail quietly back to idle. The
                // explicit click still needs feedback, unless its channel changed.
                if channel == updater.includePrereleases {
                    feedback(.failed(updater.message))
                }
            case .checking:
                break
            }
        }
        if updater.phase != .checking {
            Task { await updater.check(manual: true) }
        }
    }

    private func show(_ updater: ApplicationUpdater, language: String) {
        // A menu-bar popover sits above ordinary windows. Dismiss it before
        // bringing forward the update dialog, rather than making that dialog
        // permanently float over unrelated applications.
        onWillPresent?()
        present(updater, language)
    }
}
