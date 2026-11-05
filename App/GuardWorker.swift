import Foundation
import SwitcherCore

/// launchctl waits never run on the UI actor. The worker also orders enable/disable
/// and health queries, so a periodic query cannot run in the middle of registration.
protocol GuardWorking: Sendable {
    func registered() async -> Bool
    func enable(_ config: SafetyConfig) async throws
    func retry(_ config: SafetyConfig) async throws
    func disable() async throws
}
extension GuardWorking {
    func retry(_ config: SafetyConfig) async throws { try await enable(config) }
}

actor GuardWorker: GuardWorking {
    private let directory: URL
    private let helper: URL
    init(directory: URL, helper: URL) { self.directory = directory; self.helper = helper }
    private var service: GuardService { GuardService(files: SafetyFiles(directory: directory), helper: helper) }
    func registered() -> Bool { service.registered }
    func enable(_ config: SafetyConfig) async throws {
        try await ensure(config, forceCheck: false)
    }
    func retry(_ config: SafetyConfig) async throws {
        try await ensure(config, forceCheck: true)
    }
    private func ensure(_ config: SafetyConfig, forceCheck: Bool) async throws {
        let files = service.files
        var expected = try config.validated(); expected.enabled = true
        let startedAt = Date()
        if (try? files.loadConfig()) == expected, service.registeredHelper?.standardizedFileURL == helper.standardizedFileURL {
            if !forceCheck, let receipt = files.loadReceipt(), receipt.isFresh(for: expected), receipt.supportsUnchangedModeMarker == true { return }
            try service.requestCheck()
        } else { try service.enable(expected) }
        try await GuardStartup.wait(config: expected, startedAt: startedAt,
            receipt: { files.loadReceipt() }, stillEnabled: { (try? files.loadConfig()) == expected })
    }
    func disable() throws { try service.disable() }
}
