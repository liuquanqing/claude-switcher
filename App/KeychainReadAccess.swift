import Foundation
import Security
import LocalAuthentication

/// Background reads fail without showing SecurityAgent. Only an explicit login action
/// may request UI; a denied request is never interpreted as a missing login.
enum KeychainReadAccess {
    static func read(service: String, account: String? = nil, allowInteraction: Bool = false,
                     perform: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = { SecItemCopyMatching($0, $1) }) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = perform(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed {
            throw err("登录读取需要授权；自动刷新已跳过，可主动核验登录。")
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw err("登录存储暂不可读（状态 \(status)）；未视为退出登录。")
        }
        return data
    }
}
