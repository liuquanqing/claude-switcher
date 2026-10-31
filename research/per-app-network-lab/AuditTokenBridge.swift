import Foundation
import NetworkExtension
import Security

// Compile-only proof of supported macOS API availability. No filter entrypoint,
// manager, installation, preference mutation, socket or network request.
// A valid code signature/identifier is metadata, not proof of trusted publisher
// or protected-app enrollment. This probe deliberately supplies no classifier.
struct FlowCodeIdentity {
    let identifier: String
    let team: String?
    let codeHash: Data?
}
enum AuditTokenBridge {
    static func resolve(_ auditToken: Data?) -> FlowCodeIdentity? {
        guard let auditToken, auditToken.count == 32 else { return nil }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String else { return nil }
        return FlowCodeIdentity(identifier: identifier,
            team: values[kSecCodeInfoTeamIdentifier as String] as? String,
            codeHash: values[kSecCodeInfoUnique as String] as? Data)
    }

    static func identities(of flow: NEFilterFlow) -> (app: FlowCodeIdentity?, process: FlowCodeIdentity?) {
        // On macOS the similarly named sourceAppIdentifier property is unavailable.
        // OS-delegated work may have different app/process audit tokens.
        (resolve(flow.sourceAppAuditToken), resolve(flow.sourceProcessAuditToken))
    }

    static func revokeExistingSocket(_ flow: NEFilterSocketFlow, on provider: NEFilterDataProvider) {
        provider.update(flow, using: .drop(), for: .any)
    }
}
