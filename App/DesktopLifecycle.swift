import AppKit

/// Observe process metadata rather than polling auth or forcing a client action.
final class DesktopLifecycleObservation {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    init(center: NotificationCenter, changed: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: changed))
        }
    }
    deinit { tokens.forEach(center.removeObserver) }
}
