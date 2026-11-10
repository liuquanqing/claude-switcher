import Foundation
import AppKit
import OSLog
import SwitcherCore

@main
struct ClaudeGuard {
    private static let lifecycleLog = Logger(subsystem: "dev.claudeswitcher", category: "desktop-lifecycle")

    static func main() async {
        guard CommandLine.arguments.count == 3,
              ["--config", "--check"].contains(CommandLine.arguments[1]) else { exit(2) }
        let readOnly = CommandLine.arguments[1] == "--check"
        let configURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let files = SafetyFiles(directory: configURL.deletingLastPathComponent())
        guard configURL == files.configURL else { exit(2) }
        let support = files.directory.deletingLastPathComponent()
        let initialEvidence = DesktopModeInspector.evidence(support: support)
        let scope = initialEvidence.scope
        let session = files.loadManagedDesktop()
        let config: SafetyConfig
        do { config = try files.loadConfig() }
        catch {
            if readOnly { printDecision(SafetyDecision(.invalidConfig)); exit(1) }
            // Invalid configuration cannot silently disable an installed guard.
            let fallback = SafetyConfig(enabled: true)
            let action = await stopClaude(session: session, support: support)
            recordStopResult(action, reason: .invalidConfig)
            try? files.save(GuardReceipt(config: fallback, decision: SafetyDecision(.invalidConfig), termination: action,
                                        desktopScope: scope, desktopManaged: isManaged(session, support: support)), to: files.receiptURL)
            exit(1)
        }
        let retryCountry = config.enabled && !readOnly && isManaged(session, support: support) ? config.expectedCountry : nil
        let network = config.enabled ? await NetworkProbe().observe(mode: config.proxyMode, retrySingleTimeoutFor: retryCountry)
            : NetworkObservation(proxyConnected: false, tunOnline: false, country: nil)
        if readOnly {
            let decision = SafetyPolicy.evaluate(config, network)
            printDecision(decision)
            exit(decision.allowed ? 0 : 1)
        }
        // A user may stop protection or change its target while the request is pending.
        guard (try? files.loadConfig()) == config, files.loadManagedDesktop() == session else { exit(0) }
        let currentEvidence = DesktopModeInspector.evidence(support: support)
        let currentScope = currentEvidence.scope
        let authorized = session.flatMap { record in
            record.authorizes(initialEvidence) && record.authorizes(currentEvidence) ? record : nil
        }
        if authorized == nil, session != nil, files.loadManagedDesktop() == session {
            // An observed loss of mode evidence requires a fresh confirmation.
            // Do not give the revoked record to this tick's stop operation.
            try? FileManager.default.removeItem(at: files.managedDesktopURL)
        }
        var receipt = await GuardEngine.tick(config: config, network: network,
            stop: { await stopClaude(session: authorized, support: support) }, desktopScope: currentScope,
            desktopManaged: isManaged(authorized, support: support))
        recordStopResult(receipt.termination, reason: receipt.decision.reason)
        receipt.supportsUnchangedModeMarker = true
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

    private static func recordStopResult(_ action: String, reason: SafetyReason) {
        guard action == "closed" || action == "failed" else { return }
        lifecycleLog.notice("Network guard close result: \(action, privacy: .public); reason: \(reason.rawValue, privacy: .public)")
    }

    @MainActor static func stopClaude(session: ManagedDesktopSession?, support: URL) async -> String {
        guard let owned = application(session, support: support) else { return "not_managed" }
        lifecycleLog.notice("Network guard requested managed Claude Desktop to quit")
        owned.terminate()
        for _ in 0..<8 {
            if application(session, support: support) == nil { return "closed" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if let remaining = application(session, support: support) {
            lifecycleLog.notice("Network guard requested forced termination of managed Claude Desktop")
            remaining.forceTerminate()
        }
        for _ in 0..<4 {
            if application(session, support: support) == nil { return "closed" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return application(session, support: support) == nil ? "closed" : "failed"
    }
}
