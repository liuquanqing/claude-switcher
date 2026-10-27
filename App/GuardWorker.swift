import Foundation
import SwitcherCore

/// launchctl waits never run on the UI actor. The worker also orders enable/disable
/// and health queries, so a periodic query cannot run in the middle of registration.
protocol GuardWorking: Sendable {
    func registered() async -> Bool
    func enable(_ config: SafetyConfig) async throws
    func disable() async throws
}

actor GuardWorker: GuardWorking {
    private let directory: URL
    private let helper: URL
    init(directory: URL, helper: URL) { self.directory = directory; self.helper = helper }
    private var service: GuardService { GuardService(files: SafetyFiles(directory: directory), helper: helper) }
    func registered() -> Bool { service.registered }
    func enable(_ config: SafetyConfig) throws { try service.enable(config) }
    func disable() throws { try service.disable() }
}
