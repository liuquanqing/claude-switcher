import Foundation
import Security
import CommonCrypto

/// Serializes decryption and Keychain access used by concurrent profile refreshes.
/// The algorithm and stored format remain the original Electron v10 format.
actor DesktopTokenReader {
    private var cachedKey: Data?
    private let secretProvider: (@Sendable () throws -> Data)?
    init(secretProvider: (@Sendable () throws -> Data)? = nil) {
        self.secretProvider = secretProvider
    }
    static func systemSecret(allowInteraction: Bool = false) throws -> Data {
        guard let data = try KeychainReadAccess.read(service: "Claude Safe Storage", allowInteraction: allowInteraction) else {
            throw err("Claude Safe Storage 不存在；未把无法解密当作退出登录。")
        }
        return data
    }
    private func key(allowInteraction: Bool) throws -> Data {
        if let cachedKey { return cachedKey }
        let secret = try secretProvider?() ?? Self.systemSecret(allowInteraction: allowInteraction)
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
    private func decrypt(_ value: String, allowInteraction: Bool) throws -> Data {
        guard let raw = Data(base64Encoded: value), raw.prefix(3) == Data("v10".utf8),
              raw.count > 3, (raw.count - 3) % 16 == 0 else { throw err("桌面登录加密格式不支持或已损坏。") }
        let body = raw.dropFirst(3), key = try key(allowInteraction: allowInteraction), iv = [UInt8](repeating: 0x20, count: 16)
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
    func read(directory: URL, allowExpired: Bool = false, allowInteraction: Bool = false) throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent("config.json")) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        catch { throw err("桌面配置不可读，未把读取失败当作退出登录。") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw err("桌面配置格式不兼容，未修改档案。")
        }
        guard let raw = object["oauth:tokenCacheV2"], !(raw is NSNull) else { return nil }
        guard let encoded = raw as? String else { throw err("桌面登录字段格式不兼容。") }
        let parsed = try JSONSerialization.jsonObject(with: decrypt(encoded, allowInteraction: allowInteraction))
        return try Self.extractProfileToken(from: parsed, allowExpired: allowExpired, now: Date().timeIntervalSince1970 * 1000)
    }

    static func extractProfileToken(from parsed: Any, allowExpired: Bool, now: Double) throws -> String? {
        guard parsed is [String: Any] || parsed is [Any] else {
            throw err("桌面登录缓存格式不兼容。")
        }
        let candidates = Self.profileTokenCandidates(in: parsed, depth: 0)
        return candidates
            .filter { allowExpired || $0.1 > now }
            .max { $0.1 < $1.1 }?.0
    }

    private static func numericExpiry(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func hasProfileScope(_ entry: [String: Any]) -> Bool {
        if let scopes = entry["scopes"] as? [String], scopes.contains(where: { $0.contains("user:profile") }) {
            return true
        }
        if let scope = entry["scope"] as? String, scope.contains("user:profile") {
            return true
        }
        return false
    }

    private static func extractCandidate(from entry: [String: Any]) -> (String, Double)? {
        guard let token = (entry["token"] as? String) ?? (entry["accessToken"] as? String),
              !token.isEmpty,
              let expiry = numericExpiry(entry["expiresAt"]) else { return nil }
        return (token, expiry)
    }

    private static func profileTokenCandidates(in node: Any, depth: Int) -> [(String, Double)] {
        guard depth <= 4 else { return [] }
        if let dict = node as? [String: Any] {
            var results: [(String, Double)] = []
            if hasProfileScope(dict), let candidate = extractCandidate(from: dict) {
                results.append(candidate)
            }
            for (key, value) in dict {
                if key.contains("user:profile"), let entry = value as? [String: Any],
                   let candidate = extractCandidate(from: entry) {
                    results.append(candidate)
                } else if value is [String: Any] || value is [Any] {
                    results.append(contentsOf: profileTokenCandidates(in: value, depth: depth + 1))
                }
            }
            return results
        }
        if let array = node as? [Any] {
            return array.flatMap { profileTokenCandidates(in: $0, depth: depth + 1) }
        }
        return []
    }
}
