import Foundation
import Security
import LocalAuthentication
import SwitcherCore

/// Current-login recovery may update only our backup, with no automatic UI.
enum KeychainWriteAccess {
    static func backup(service: String, account: String, data: Data, allowInteraction: Bool,
                       update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
                       add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd) throws {
        guard service == switcherService else { throw SafetyError("当前登录续期不由切换器写入原生凭据。") }
        let context = LAContext();context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,kSecAttrAccount as String:account,
            kSecUseAuthenticationContext as String:context]
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var status = update(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data;status = add(query as CFDictionary,nil)
        }
        if [errSecInteractionNotAllowed,errSecAuthFailed,errSecUserCanceled].contains(status) { throw CLIInteractionRequired() }
        guard status == errSecSuccess else { throw SafetyError("当前 CLI 已由官方程序处理，备份尚未保存，请稍后重试。") }
    }
}
