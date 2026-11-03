import AppKit

/// Explicit dismissal supplements NSPopover.transient after menus, authorization
/// prompts and another window have changed the application's key window.
@MainActor
final class PopoverDismissalController: NSObject, NSPopoverDelegate {
    private weak var popover: NSPopover?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    func attach(to popover: NSPopover, anchor: NSView?) {
        stopMonitoring()
        self.popover = popover
        self.anchor = anchor
        popover.delegate = self
    }

    func popoverDidShow(_ notification: Notification) {
        startMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        stopMonitoring()
    }

    private func startMonitoring() {
        stopMonitoring()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleLocalClick(in: event.window, location: event.locationInWindow)
            }
            // Closing the panel must not consume the user's click in another window.
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// A status-button click is handled by toggle(); do not close first and then
    /// accidentally reopen. Owned child windows include SwiftUI help popovers.
    func handleLocalClick(in window: NSWindow?, location: NSPoint = .zero) {
        guard let popover, popover.isShown,
              let panel = popover.contentViewController?.view.window else { return }
        if let window, let anchor, window === anchor.window,
           anchor.bounds.contains(anchor.convert(location, from: nil)) { return }
        if let window, Self.belongsToPanel(window, panel: panel) { return }
        // Menu tracking can report a nil event window. Let AppKit finish the
        // menu action; genuine clicks in other applications use the global monitor.
        guard window != nil else { return }
        close()
    }

    static func belongsToPanel(_ window: NSWindow, panel: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let candidate = current {
            if candidate === panel { return true }
            current = candidate.parent ?? candidate.sheetParent
        }
        return false
    }

    func close() {
        guard popover?.isShown == true else { return }
        popover?.close()
    }

    func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        localMonitor = nil
        globalMonitor = nil
        resignObserver = nil
    }
}
