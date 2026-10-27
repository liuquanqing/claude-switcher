import Foundation

public enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case shadowrocket, auto
}

public struct SafetyConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var expectedCountry: String
    public var proxyMode: ProxyMode
    public static let interval: TimeInterval = 10
    public static let maximumReceiptAge: TimeInterval = 30

    public init(enabled: Bool = false, expectedCountry: String = "SG", proxyMode: ProxyMode = .shadowrocket) {
        self.enabled = enabled
        self.expectedCountry = expectedCountry
        self.proxyMode = proxyMode
    }

    public func validated() throws -> SafetyConfig {
        let country = expectedCountry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard country.utf8.count == 2, country.utf8.allSatisfy({ (65...90).contains($0) }),
              Locale.Region.isoRegions.contains(where: { $0.identifier == country }) else {
            throw SafetyError("请输入有效的两位国家代码，例如 SG。")
        }
        return SafetyConfig(enabled: enabled, expectedCountry: country, proxyMode: proxyMode)
    }
}

public struct SafetyError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct NetworkObservation: Codable, Equatable {
    public var proxyConnected: Bool
    public var tunOnline: Bool
    public var country: String?
    public var routesDisagree: Bool
    public init(proxyConnected: Bool, tunOnline: Bool, country: String?, routesDisagree: Bool = false) {
        self.proxyConnected = proxyConnected; self.tunOnline = tunOnline; self.country = country
        self.routesDisagree = routesDisagree
    }

    public static func sharedCountry(_ countries: [String?]) -> String? {
        guard !countries.isEmpty, countries.allSatisfy({ $0 != nil }),
              Set(countries.compactMap { $0 }).count == 1 else { return nil }
        return countries[0]
    }

    public static func countryFromTrace(_ text: String, httpStatus: Int) -> String? {
        guard httpStatus == 200 else { return nil }
        let values = text.split(separator: "\n").filter { $0.hasPrefix("loc=") }.map { String($0.dropFirst(4)) }
        guard values.count == 1, let value = values.first, value.utf8.count == 2,
              value.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return value
    }

    public static func shadowrocketConnected(_ text: String) -> Bool {
        text.split(separator: "\n").contains {
            $0.contains("com.liguangming.Shadowrocket") && $0.contains("(Connected)")
        }
    }
    public static func hasSupportedTUN(_ text: String) -> Bool {
        text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("inet 198.18.") }
    }
}

public enum SafetyReason: String, Codable, Sendable {
    case allowed, disabled, invalidConfig, proxyDisconnected, tunMissing, countryUnknown, countryMismatch
    case guardUnavailable, staleReceipt, terminationFailed
    case routesDisagree
    case unsupportedMode
}

public struct SafetyDecision: Codable, Equatable, Sendable {
    public var reason: SafetyReason
    public var expectedCountry: String?
    public var observedCountry: String?
    public var allowed: Bool { reason == .allowed }
    public init(_ reason: SafetyReason, expected: String? = nil, observed: String? = nil) {
        self.reason = reason; self.expectedCountry = expected; self.observedCountry = observed
    }
    public var message: String {
        switch reason {
        case .allowed: return "网络检查通过 · \(observedCountry ?? "")"
        case .disabled: return "保护未启用；启用后才能从切换器打开 Claude。"
        case .invalidConfig: return "保护配置无效，请重新保存目标国家。"
        case .proxyDisconnected: return "代理未连接，已阻止打开 Claude。"
        case .tunMissing: return "未检测到支持的 TUN，已阻止打开 Claude。"
        case .countryUnknown: return "无法确认出口国家，已阻止打开 Claude。"
        case .countryMismatch: return "出口国家 \(observedCountry ?? "未知") 与目标 \(expectedCountry ?? "未知") 不一致。"
        case .guardUnavailable: return "独立守卫未注册，请重新启用保护。"
        case .staleReceipt: return "守卫回执缺失或已过期，不能确认后台保护在线。"
        case .terminationFailed: return "网络检查失败，但未能关闭 Claude，请立即手动退出。"
        case .routesDisagree: return "Claude 各域名的出口国家不一致，已阻止打开。"
        case .unsupportedMode: return "桌面配置为 API 或模式未确认；订阅保护入口不会接管该模式。"
        }
    }
}

public enum SafetyPolicy {
    public static func evaluate(_ config: SafetyConfig, _ network: NetworkObservation) -> SafetyDecision {
        guard let config = try? config.validated() else { return SafetyDecision(.invalidConfig) }
        guard config.enabled else { return SafetyDecision(.disabled) }
        guard network.proxyConnected else { return SafetyDecision(.proxyDisconnected) }
        guard network.tunOnline else { return SafetyDecision(.tunMissing) }
        guard !network.routesDisagree else { return SafetyDecision(.routesDisagree) }
        guard let country = network.country,
              (try? SafetyConfig(expectedCountry: country).validated().expectedCountry) == country else {
            return SafetyDecision(.countryUnknown)
        }
        return SafetyDecision(country == config.expectedCountry ? .allowed : .countryMismatch,
                              expected: config.expectedCountry, observed: country)
    }
}

public struct GuardReceipt: Codable, Equatable {
    public var checkedAt: Date
    public var config: SafetyConfig
    public var decision: SafetyDecision
    public var termination: String
    public var desktopScope: DesktopProtectionScope?
    public var desktopManaged: Bool?
    public init(checkedAt: Date = Date(), config: SafetyConfig, decision: SafetyDecision, termination: String = "not_needed",
                desktopScope: DesktopProtectionScope = .subscription, desktopManaged: Bool = false) {
        self.checkedAt = checkedAt; self.config = config; self.decision = decision; self.termination = termination
        self.desktopScope = desktopScope; self.desktopManaged = desktopManaged
    }
    public func isFresh(for expected: SafetyConfig, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(checkedAt)
        return config == expected && age >= 0 && age <= SafetyConfig.maximumReceiptAge
    }
}

public enum LaunchGate {
    public static func evaluate(config: SafetyConfig, registered: Bool, receipt: GuardReceipt?,
                                network: NetworkObservation, now: Date = Date(), target: ProtectedTarget = .desktop,
                                desktopScope: DesktopProtectionScope? = nil) -> SafetyDecision {
        guard config.enabled else { return SafetyDecision(.disabled) }
        guard registered else { return SafetyDecision(.guardUnavailable) }
        guard receipt?.isFresh(for: config, now: now) == true else { return SafetyDecision(.staleReceipt) }
        guard receipt?.termination != "failed" else { return SafetyDecision(.terminationFailed) }
        if target == .desktop {
            let scope = desktopScope ?? receipt?.desktopScope ?? .unknown
            guard scope == .subscription, receipt?.desktopScope == scope else { return SafetyDecision(.unsupportedMode) }
        }
        return SafetyPolicy.evaluate(config, network)
    }

    // Checks before touching accounts and again after preparation, just before opening.
    public static func run(check: () async -> SafetyDecision, prepare: () async throws -> Void,
                           launch: () async throws -> Void) async throws {
        var decision = await check()
        guard decision.allowed else { throw SafetyError(decision.message) }
        try await prepare()
        decision = await check()
        guard decision.allowed else { throw SafetyError("操作已准备完成，但打开前复检未通过：" + decision.message) }
        try await launch()
    }
}

public enum GuardEngine {
    public static func tick(config: SafetyConfig, network: NetworkObservation,
                            stop: () async -> String, now: Date = Date(),
                            desktopScope: DesktopProtectionScope = .subscription,
                            desktopManaged: Bool = true) async -> GuardReceipt {
        let decision = SafetyPolicy.evaluate(config, network)
        let shouldStop = config.enabled && desktopManaged && desktopScope == .subscription && !decision.allowed
        let action = shouldStop ? await stop() : "not_needed"
        return GuardReceipt(checkedAt: now, config: config, decision: decision, termination: action,
                            desktopScope: desktopScope, desktopManaged: desktopManaged)
    }
}

public enum AccountIdentity {
    public static func requireMatch(expected: String?, observed: String?) throws {
        guard let expected, !expected.isEmpty, let observed, !observed.isEmpty else {
            throw SafetyError("无法确认终端登录归属，未备份或覆盖凭据；请先刷新账号信息。")
        }
        guard expected == observed else {
            throw SafetyError("终端登录与离开账号不一致，未备份或覆盖凭据；请先结束旧终端会话并核对登录。")
        }
    }
}

public struct SafetyFiles: Sendable {
    public let directory: URL
    public var configURL: URL { directory.appendingPathComponent("protection.json") }
    public var receiptURL: URL { directory.appendingPathComponent("guard-status.json") }
    public var managedDesktopURL: URL { directory.appendingPathComponent("managed-desktop.json") }
    public init(directory: URL) { self.directory = directory }
    public func loadConfig() throws -> SafetyConfig {
        try JSONDecoder().decode(SafetyConfig.self, from: Data(contentsOf: configURL)).validated()
    }
    public func loadReceipt() -> GuardReceipt? {
        (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(GuardReceipt.self, from: $0) }
    }
    public func loadManagedDesktop() -> ManagedDesktopSession? {
        (try? Data(contentsOf: managedDesktopURL)).flatMap { try? JSONDecoder().decode(ManagedDesktopSession.self, from: $0) }
    }
    public func save<T: Encodable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
