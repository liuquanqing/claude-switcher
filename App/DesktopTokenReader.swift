import Foundation
import Security
import CommonCrypto

/// Serializes decryption and Keychain access used by concurrent profile refreshes.
/// The algorithm and stored format remain the original Electron v10 format.
actor DesktopTokenReader {
    private var cachedKey: Data?
    private let secretProvider: @Sendable () throws -> Data
    init(secretProvider: @escaping @Sendable () throws -> Data = { try DesktopTokenReader.systemSecret() }) {
        self.secretProvider = secretProvider
    }
    static func systemSecret() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw err("无法读取 Claude Safe Storage（状态 \(status)）；未把权限失败当成退出登录。")
        }
        return data
    }
    private func key() throws -> Data {
        if let cachedKey { return cachedKey }
        let secret = try secretProvider()
        guard !secret.isEmpty else { throw err("Claude Safe Storage 内容为空，未读取登录。") }
        var output = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let result = output.withUnsafeMutableBytes { keyBytes in
            secret.withUnsafeBytes { bytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                                    secret.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                    1003, keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard result == kCCSuccess else { throw err("桌面登录解密密钥派生失败。") }
        cachedKey = output; return output
    }
    private func decrypt(_ value: String) throws -> Data {
        guard let raw = Data(base64Encoded: value), raw.prefix(3) == Data("v10".utf8),
              raw.count > 3, (raw.count - 3) % 16 == 0 else { throw err("桌面登录加密格式不支持或已损坏。") }
        let body = raw.dropFirst(3), key = try key(), iv = [UInt8](repeating: 0x20, count: 16)
        var output = Data(count: body.count + 16), moved = 0
        let capacity = output.count
        let result = output.withUnsafeMutableBytes { target in
            body.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, 16, iv, source.baseAddress, body.count,
                            target.baseAddress, capacity, &moved)
                }
            }
        }
        guard result == kCCSuccess else { cachedKey = nil; throw err("桌面登录数据无法解密；原材料保留。") }
        return output.prefix(moved)
    }
    func read(directory: URL, allowExpired: Bool = false) throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent("config.json")) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        catch { throw err("桌面配置不可读，未把读取失败当作退出登录。") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw err("桌面配置格式不兼容，未修改档案。")
        }
        guard let raw = object["oauth:tokenCacheV2"], !(raw is NSNull) else { return nil }
        guard let encoded = raw as? String else { throw err("桌面登录字段格式不兼容。") }
        guard let tokens = try JSONSerialization.jsonObject(with: decrypt(encoded)) as? [String: [String: Any]] else {
            throw err("桌面登录缓存格式不兼容。")
        }
        let now = Date().timeIntervalSince1970 * 1000
        return tokens.filter { $0.key.contains("user:profile") }
            .compactMap { _, value -> (String, Double)? in
                guard let token = value["token"] as? String, !token.isEmpty,
                      let expiry = value["expiresAt"] as? Double, allowExpired || expiry > now else { return nil }
                return (token, expiry)
            }.max { $0.1 < $1.1 }?.0
    }
}
