import Foundation

@_silgen_name("fixture_self_audit_token")
func fixtureSelfAuditToken(_ destination: UnsafeMutablePointer<UInt8>) -> Int32

@main struct SelfIdentityProbe {
    static func main() throws {
        // Inputs are known fictional code identifiers, not user credentials.
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1].hasPrefix("dev.claudeswitcher.fixture.") else { fatalError("fixture identifier required") }
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(fixtureSelfAuditToken(&bytes) == 0)
        let identity = AuditTokenBridge.resolve(Data(bytes))
        precondition(identity?.identifier == CommandLine.arguments[1], "audit token identity did not match the signed fixture")
        precondition(identity?.codeHash?.isEmpty == false)
        precondition(AuditTokenBridge.resolve(nil) == nil)
        precondition(AuditTokenBridge.resolve(Data(repeating: 0, count: 31)) == nil)
        precondition(AuditTokenBridge.resolve(Data(repeating: 0, count: 33)) == nil)
        precondition(AuditTokenBridge.resolve(Data(repeating: 0, count: 32)) == nil)
        let result: [String: Any] = ["layer": "own-fictional-process-audit-token", "passed": true,
            "checks": 6, "signedFixtureIdentifier": identity!.identifier,
            "otherProcessExamined": false, "networkFilterFlow": "NOT_RUN", "productionReady": false]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
