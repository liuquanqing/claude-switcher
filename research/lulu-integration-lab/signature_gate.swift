import Foundation
import Security

// Static signature predicate test only. Never runs the target binaries, opens
// an XPC connection, installs a filter or modifies any preference/rule.
@main struct SignatureGate {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("fixture manifest required") }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let text = manifest["requirement"] as! String
        let cases = manifest["cases"] as! [[String: Any]]
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { fatalError("requirement invalid") }
        var results: [[String: Any]] = []
        for item in cases {
            var code: SecStaticCode?
            let path = URL(fileURLWithPath: item["path"] as! String)
            let create = SecStaticCodeCreateWithPath(path as CFURL, [], &code)
            guard create == errSecSuccess, let code else { fatalError("fixture code unreadable") }
            let status = SecStaticCodeCheckValidity(code, [], requirement)
            let match = status == errSecSuccess
            guard match == item["expectedMatch"] as! Bool else { fatalError("unexpected signature predicate result") }
            results.append(["label": item["label"]!, "matched": match, "status": status])
        }
        let result: [String: Any] = ["layer": "static-Security-requirement-on-official-binary-and-fixtures",
            "passed": true, "cases": results, "actualXPCConnection": "NOT_RUN",
            "networkFilterActivation": "NOT_RUN", "productionReady": false]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
