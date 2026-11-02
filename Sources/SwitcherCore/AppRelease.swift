import Foundation
import CoreFoundation

/// SemVer precedence, including numeric prerelease identifiers. Build metadata
/// never promotes a prerelease into a stable release.
public struct AppVersion: Comparable, Equatable, Sendable {
    public let numbers: [Int]
    public let prerelease: [String]
    public init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        guard value.count <= 128 else { return nil }
        let build = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        if build.count == 2 && (build[1].split(separator:".",omittingEmptySubsequences:false).contains(where: \.isEmpty) || !build[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })) { return nil }
        let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let main = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard main.count == 3, main.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && ($0.count == 1 || $0.first != "0") }),
              main.compactMap({ Int($0) }).count == 3 else { return nil }
        numbers = main.compactMap { Int($0) }
        prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard parts.count == 1 || !prerelease.isEmpty && prerelease.allSatisfy({
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && (!$0.allSatisfy(\.isNumber) || $0.count == 1 || $0.first != "0")
        }) else { return nil }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a,b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = a.allSatisfy(\.isNumber), bn = b.allSatisfy(\.isNumber)
            if an && bn { return a.count == b.count ? a < b : a.count < b.count }
            if an != bn { return an }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public struct AppReleaseAsset: Equatable, Sendable {
    public let name: String
    public let size: Int64
    public let downloadURL: URL
    public let sha256: String?
    public init(name: String, size: Int64, downloadURL: URL, sha256: String?) {
        self.name=name;self.size=size;self.downloadURL=downloadURL;self.sha256=sha256
    }
}
public struct AppRelease: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let pageURL: URL
    public let prerelease: Bool
    public let asset: AppReleaseAsset
    public let checksumURL: URL?
    public init(version: String, notes: String, pageURL: URL, prerelease: Bool, asset: AppReleaseAsset, checksumURL: URL? = nil) {
        self.version=version;self.notes=notes;self.pageURL=pageURL;self.prerelease=prerelease;self.asset=asset;self.checksumURL=checksumURL
    }
}

public enum AppReleasePolicy {
    public static let repository = "liuquanqing/claude-switcher"
    public static let bundleID = "dev.claudeswitcher.candidate"
    public static let releasesURL = URL(string: "https://api.github.com/repos/" + repository + "/releases?per_page=30")!
    public static func permitsHTTPS(_ url: URL, redirectedAsset: Bool = false) -> Bool {
        guard url.scheme == "https", url.user == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        if host == "github.com" || host == "api.github.com" { return true }
        return redirectedAsset && ["release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(host)
    }
    public static func hash(_ value: String?) -> String? {
        guard let value, value.count == 64, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return value.lowercased()
    }
    public static func checksum(_ data: Data, filename: String) throws -> String {
        guard data.count <= 262144, let text = String(data: data, encoding: .utf8) else { throw SafetyError("更新校验文件无效。") }
        let found = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "") == filename else { return nil }
            return hash(String(fields[0]))
        }
        guard found.count == 1, let result = found.first else { throw SafetyError("更新包缺少唯一的校验值。") }
        return result
    }
    public static func select(_ data: Data, current: String, architecture: String, includePrereleases: Bool) throws -> AppRelease? {
        guard let installed = AppVersion(current), ["arm64", "x86_64"].contains(architecture), data.count <= 2_097_152,
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SafetyError("版本信息无法确认。") }
        var candidates: [(AppVersion, AppRelease)] = []
        for row in list {
            guard row["draft"] as? Bool == false, let preview = row["prerelease"] as? Bool,
                  let tag = row["tag_name"] as? String, let version = AppVersion(tag), version > installed,
                  includePrereleases || !preview && version.prerelease.isEmpty,
                  let page = row["html_url"] as? String, let url = URL(string: page),
                  page == "https://github.com/" + repository + "/releases/tag/" + tag,
                  let assets = row["assets"] as? [[String: Any]] else { continue }
            let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            func assetURL(_ asset: [String: Any]) -> URL? {
                guard let name = asset["name"] as? String, let raw = asset["browser_download_url"] as? String,
                      let target = URL(string: raw), permitsHTTPS(target), target.host == "github.com",
                      target.path == "/" + repository + "/releases/download/" + tag + "/" + name else { return nil }
                return target
            }
            let prefix = "ClaudeSwitcher-" + value + "-" + architecture
            let available = assets.filter { [prefix + ".dmg", prefix + "-developer-id-preview.dmg"].contains($0["name"] as? String ?? "") }
            guard available.count == 1, let item = available.first, let target = assetURL(item),
                  let size = item["size"] as? NSNumber, CFGetTypeID(size) != CFBooleanGetTypeID(),
                  size.int64Value > 0, size.int64Value <= 2_147_483_648, size.doubleValue == Double(size.int64Value),
                  let name = item["name"] as? String else { continue }
            let digest = (item["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? hash(String($0.dropFirst(7))) : nil }
            let sums = assets.filter { $0["name"] as? String == "SHA256SUMS" }
            let checksumURL = sums.count == 1 ? assetURL(sums[0]) : nil
            guard digest != nil || checksumURL != nil else { continue }
            candidates.append((version, AppRelease(version: value, notes: String((row["body"] as? String ?? "").prefix(12000)), pageURL: url,
                prerelease: preview || !version.prerelease.isEmpty,
                asset: AppReleaseAsset(name: name, size: size.int64Value, downloadURL: target, sha256: digest), checksumURL: checksumURL)))
        }
        return candidates.max(by: { $0.0 < $1.0 })?.1
    }
}
