import Foundation

public enum APIConfigurationStatus: String, Codable, Sendable {
    case subscription, magpie, ccSwitch, unknownAPI, conflict, unconfirmed
    public var managerBundleID: String? {
        switch self {
        case .magpie: return "com.yetone.magpie"
        case .ccSwitch: return "com.ccswitch.desktop"
        default: return nil
        }
    }
}

public enum APIConfigurationInspector {
    public static let magpieID = "00000000-0000-4000-8000-6d6167706965"
    public static let ccSwitchID = "00000000-0000-4000-8000-000000157210"
    private static func knownID(_ value: Any?) -> String? {
        guard let raw = value as? String, let id = UUID(uuidString: raw)?.uuidString.lowercased(),
              [magpieID, ccSwitchID].contains(id) else { return nil }
        return id
    }
    public static func classify(scope: DesktopProtectionScope, meta: Data?, profiles: [String: Data]) -> APIConfigurationStatus {
        guard scope == .api else { return scope == .subscription ? .subscription : .unconfirmed }
        guard let meta else { return .unknownAPI }
        guard let object = try? CLIJSON.object(meta) else { return .unconfirmed }
        guard let id = knownID(object["appliedId"]) else { return .unknownAPI }
        guard let entries = object["entries"] as? [[String: Any]] else { return .unconfirmed }
        let matches = entries.filter { knownID($0["id"]) == id }
        guard matches.count == 1 else { return matches.count > 1 ? .conflict : .unknownAPI }
        guard let data = profiles[id], let profile = try? CLIJSON.object(data),
              profile["inferenceProvider"] as? String == "gateway" else { return .unknownAPI }
        return id == magpieID ? .magpie : .ccSwitch
    }
    public static func read(support: URL, scope: DesktopProtectionScope) -> APIConfigurationStatus {
        guard scope == .api else { return scope == .subscription ? .subscription : .unconfirmed }
        let library = support.appendingPathComponent("Claude-3p/configLibrary")
        let meta: Data
        do { meta = try Data(contentsOf: library.appendingPathComponent("_meta.json")) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return .unknownAPI }
        catch { return .unconfirmed }
        guard let object = try? CLIJSON.object(meta), let id = knownID(object["appliedId"]) else {
            return classify(scope: scope, meta: meta, profiles: [:])
        }
        // Only whitelisted fixed filenames are read. No path or command from config is run.
        let profile = try? Data(contentsOf: library.appendingPathComponent(id + ".json"))
        return classify(scope: scope, meta: meta, profiles: profile.map { [id: $0] } ?? [:])
    }
}
