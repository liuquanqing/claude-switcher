import AppKit
import Foundation

/// A credential-free application used only by the signed updater integration test.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private let arguments = CommandLine.arguments
    private var lifetime: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let mode = Bundle.main.object(forInfoDictionaryKey: "CSQABehavior") as? String ?? ""
        let record: [String: Any] = ["build": build, "pid": ProcessInfo.processInfo.processIdentifier,
                                    "application": Bundle.main.bundleURL.path, "behavior": mode]
        func write(_ value: [String: Any], to url: URL) {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
                try? data.write(to: url, options: .atomic)
            }
        }
        if let index = arguments.firstIndex(of: "--fixture-start"), arguments.indices.contains(index + 1) {
            write(record, to: URL(fileURLWithPath: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--complete-update"), arguments.indices.contains(index + 1) {
            let planFile = URL(fileURLWithPath: arguments[index + 1])
            if let data = try? Data(contentsOf: planFile),
               let plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let id = plan["id"] as? String {
                write(record, to: planFile.deletingLastPathComponent().appendingPathComponent("launched-" + build + ".json"))
                if mode == "ack", plan["newBuild"] as? String == build {
                    write(["id": id, "state": "complete"],
                          to: planFile.deletingLastPathComponent().appendingPathComponent("acknowledged.json"))
                }
            }
        }
        lifetime = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Bundle.main.object(forInfoDictionaryKey: "CSQABehavior") as? String == "refuse" ? .terminateCancel : .terminateNow
    }
}

@main enum FixtureApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = FixtureDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
