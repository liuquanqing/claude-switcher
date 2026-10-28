import Foundation
import SwitcherCore

/// Only called for Store(demo:true). The actual service writes temporary fictional
/// indexes and backups; it cannot resolve any user's Claude profile or transcript.
enum SessionTransferDemo {
    static func environment(scenario: String = "normal") throws -> (SessionTransferEnvironment, URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("claude-transfer-demo-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let a = root.appendingPathComponent("Business"), b = root.appendingPathComponent("Personal"), api = root.appendingPathComponent("Claude-3p")
        let transcripts = root.appendingPathComponent("projects/demo-project")
        for path in [a.appendingPathComponent("claude-code-sessions/account-business/org-team"), b.appendingPathComponent("claude-code-sessions/account-personal/org-personal"), api.appendingPathComponent("claude-code-sessions/api-local/space-one"), api.appendingPathComponent("claude-code-sessions/api-local/space-two"), transcripts] {
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
        }
        func json(_ value: [String: Any], _ path: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: path) }
        let now = Date().timeIntervalSince1970 * 1000
        let examples: [(String, String, Int, Int?)] = [("ui", "设置面板排版整理", 18, nil), ("api", "接口异常与重试处理", 28, 12), ("deploy", "发布前检查清单", 5, 13), ("chain", "长任务续接记录", 2, 120)]
        for (i, example) in examples.enumerated() {
            let (id, title, turns, old) = example
            let cli = "cli-" + id
            let base: [String: Any] = ["sessionId": "logical-" + id, "cliSessionId": cli, "title": title, "cwd": "/demo/atlas", "completedTurns": turns, "lastActivityAt": now - Double(i * 300_000)]
            try json(base, a.appendingPathComponent("claude-code-sessions/account-business/org-team/local_\(id).json"))
            try Data("{\"sessionId\":\"\(cli)\",\"message\":\"FICTIONAL TEST ONLY\"}\n".utf8).write(to: transcripts.appendingPathComponent(cli + ".jsonl"))
            if let old {
                var target = base; target["completedTurns"] = old; target["lastActivityAt"] = now - (old > turns ? 0 : 600_000)
                if id == "chain" { target["cliSessionId"] = "cli-previous" }
                try json(target, b.appendingPathComponent("claude-code-sessions/account-personal/org-personal/local_\(id).json"))
            }
        }
        let endpoints = [SessionTransferEndpoint(id: "profile:Business", name: "Business", root: a), SessionTransferEndpoint(id: "profile:Personal", name: "Personal", root: b), SessionTransferEndpoint(id: "api", name: "API 工作区", root: api)]
        let environment = SessionTransferEnvironment(endpoints: endpoints, activeEndpointIDs: [], transcripts: root.appendingPathComponent("projects"), backups: root.appendingPathComponent("backups"))
        if scenario == "recovery" || scenario == "conflict" {
            let engine = SessionTransferService(transcripts: environment.transcripts, backups: environment.backups)
            let source = try engine.spaces(in: endpoints[0])[0], target = try engine.spaces(in: endpoints[1])[0]
            let plan = try engine.plan(source: source, target: target, selected: ["local_ui.json"], updateExisting: false)
            var receipt = try engine.execute(plan); receipt.state = .recoveryRequired
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(receipt).write(to: environment.backups.appendingPathComponent(receipt.id + "/receipt.json"))
            if scenario == "conflict" {
                let file = target.directory.appendingPathComponent("local_ui.json")
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                object["completedTurns"] = 999
                try json(object, file)
            }
        }
        return (environment, root)
    }
}
