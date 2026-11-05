import AppKit
import Foundation

@main enum FixtureControl {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else { exit(2) }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        let app = URL(fileURLWithPath: args[3]).standardizedFileURL
        guard root.path.contains("/_qa/signed-update/"), app.path.hasPrefix(root.path + "/"),
              app.pathExtension == "app" else { exit(2) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.claudeswitcher.candidate")
            .filter { $0.bundleURL?.standardizedFileURL.path == app.path }
        if args[1] == "running" { print(running.map { String($0.processIdentifier) }.joined(separator: ",")); return }
        if args[1] == "quit" { for application in running { _ = application.terminate() }; return }
        if args[1] == "cleanup" {
            // Only credential-free test processes at the exact fixture path.
            for application in running { _ = application.forceTerminate() }; return
        }
        guard args[1] == "open", args.count == 5 else { exit(2) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--fixture-start", args[4]]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
