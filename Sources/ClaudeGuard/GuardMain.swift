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
        let config: SafetyConfig
        do { config = try files.loadConfig() }
        catch {
            if readOnly { printDecision(SafetyDecision(.invalidConfig)); exit(1) }
            // Invalid configuration cannot silently disable an installed guard.
            let fallback = SafetyConfig(enabled: true)
            let action = await stopClaude()
            try? files.save(GuardReceipt(config: fallback, decision: SafetyDecision(.invalidConfig), termination: action), to: files.receiptURL)
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
        guard (try? files.loadConfig()) == config else { exit(0) }
        let receipt = await GuardEngine.tick(config: config, network: network, stop: stopClaude)
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

    @MainActor static func stopClaude() async -> String {
        let running = { NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop") }
        guard !running().isEmpty else { return "not_running" }
        running().forEach { $0.terminate() }
        for _ in 0..<8 {
            if running().isEmpty { return "closed" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        running().forEach { $0.forceTerminate() }
        for _ in 0..<4 {
            if running().isEmpty { return "closed" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return running().isEmpty ? "closed" : "failed"
    }
}
