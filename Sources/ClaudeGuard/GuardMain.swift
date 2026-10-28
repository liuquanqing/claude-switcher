import Foundation
import AppKit
import SwitcherCore

@main
struct ClaudeGuard {
    static func main() async {
        guard CommandLine.arguments.count == 3,
              ["--config", "--check"].contains(CommandLine.arguments[1]) else { exit(2) }
        let readOnly = CommandLine.arguments[1] == "--check"
        let configURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let files = SafetyFiles(directory: configURL.deletingLastPathComponent())
        guard configURL == files.configURL else { exit(2) }
        let support = files.directory.deletingLastPathComponent()
        let scope = DesktopModeInspector.read(support: support)
        let session = files.loadManagedDesktop()
        let config: SafetyConfig
        do { config = try files.loadConfig() }
        catch {
            if readOnly { printDecision(SafetyDecision(.invalidConfig)); exit(1) }
            // Invalid configuration cannot silently disable an installed guard.
            let fallback = SafetyConfig(enabled: true)
            let action = await stopClaude(session: session, support: support)
            try? files.save(GuardReceipt(config: fallback, decision: SafetyDecision(.invalidConfig), termination: action,
                                        desktopScope: scope, desktopManaged: isManaged(session, support: support)), to: files.receiptURL)
            exit(1)
        }
        let network = config.enabled ? await NetworkProbe().observe(mode: config.proxyMode)
            : NetworkObservation(proxyConnected: false, tunOnline: false, country: nil)
        if readOnly {
            let decision = SafetyPolicy.evaluate(config, network)
            printDecision(decision)
            exit(decision.allowed ? 0 : 1)
        }
        // A user may stop protection or change its target while the request is pending.
        guard (try? files.loadConfig()) == config, files.loadManagedDesktop() == session else { exit(0) }
        let currentScope = DesktopModeInspector.read(support: support)
        if currentScope != .subscription, session != nil, files.loadManagedDesktop() == session {
            // Revoke only our own process record; leave API/unknown clients untouched.
            try? FileManager.default.removeItem(at: files.managedDesktopURL)
        }
        let receipt = await GuardEngine.tick(config: config, network: network,
            stop: { await stopClaude(session: session, support: support) }, desktopScope: currentScope,
            desktopManaged: isManaged(session, support: support))
        do { try files.save(receipt, to: files.receiptURL) }
        catch { exit(1) }
    }

    static func printDecision(_ decision: SafetyDecision) {
        struct CheckReport: Encodable {
            let scope = "network_policy_only"
            let launchGate = "not_evaluated"
            let authenticatedAccount = "not_evaluated"
            let processAction = "none"
            let runtimeStateWritten = false
            let decision: SafetyDecision
        }
        if let data = try? JSONEncoder().encode(CheckReport(decision: decision)) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    @MainActor static func application(_ session: ManagedDesktopSession?, support: URL) -> NSRunningApplication? {
        guard let session, let application = NSRunningApplication(processIdentifier: session.pid),
              application.bundleIdentifier == "com.anthropic.claudefordesktop",
              session.authorizes(DesktopModeInspector.evidence(support: support)),
              session.matches(pid: application.processIdentifier, launchedAt: application.launchDate) else { return nil }
        return application
    }
    @MainActor static func isManaged(_ session: ManagedDesktopSession?, support: URL) -> Bool { application(session, support: support) != nil }
    @MainActor static func stopClaude(session: ManagedDesktopSession?, support: URL) async -> String {
        guard let owned = application(session, support: support) else { return "not_managed" }
        owned.terminate()
        for _ in 0..<8 {
            if application(session, support: support) == nil { return "closed" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        application(session, support: support)?.forceTerminate()
        for _ in 0..<4 {
            if application(session, support: support) == nil { return "closed" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return application(session, support: support) == nil ? "closed" : "failed"
    }
}
