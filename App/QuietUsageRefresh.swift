import Foundation
import SwitcherCore

struct UsageHTTPFailure: LocalizedError {
    let code: Int
    let retryAfter: Date?
    var errorDescription: String? {
        code == 429 ? "额度查询暂受限，稍后自动重试。" : code == 401 || code == 403
            ? "保存登录暂不可用，保留原额度；可手动刷新确认。" : "额度查询未完成，保留原数据。"
    }
    static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }
}

private final class UsageRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum QuietUsageHTTP {
    static func validate(_ response: URLResponse, now: Date = Date()) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw UsageHTTPFailure(code: code, retryAfter: UsageHTTPFailure.retryDate(
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), now: now)
                ?? (code == 429 ? now.addingTimeInterval(900) : nil))
        }
    }
    static func read(_ access: String) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: UsageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-switcher", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }
}

/// Kept in memory only. Never log or persist access tokens.
struct QuietUsageContext: Equatable {
    let profile: String
    let identity: CLIIdentity
    let access: String
    let scope: DesktopProtectionScope
}

@MainActor extension Store {
    func quietUsageContext() async throws -> QuietUsageContext {
        let name = current
        let scope = protection.desktopScope
        guard try confirmedCurrentProfile() == name, DesktopModeInspector.read(support: support) == scope else {
            throw SafetyError("账号已变化，未查询额度。")
        }
        let identity: CLIIdentity
        let access: String
        switch scope {
        case .subscription:
            let desktop = try await profileDescriptor(name, allowInteraction: false)
            guard let confirmed = desktop.identity, confirmed.isComplete,
                  let value = try await token(for: profileDir(name), allowInteraction: false),
                  active?.snapshot?.identityTokenDigest == desktopTokenDigest(value) else {
                throw SafetyError("当前订阅登录尚未就绪，保留原额度。")
            }
            identity = confirmed; access = value
        case .api:
            // API mode still shows subscription quota, never the API provider's balance.
            guard cliConfiguration().allowsSubscriptionMutation else { throw SafetyError("默认 CLI 不是订阅登录，保留原额度。") }
            let io = NativeCLIStorage(allowInteraction: false)
            let login = try CLIOwnedLogin(credentials: io.readCredentials(), identityDocument: io.readIdentityDocument())
            guard let confirmed = try login.identity, confirmed.isComplete, let value = login.usableAccessToken(now: Date()) else {
                throw SafetyError("默认 CLI 订阅登录尚未就绪，保留原额度。")
            }
            identity = confirmed; access = value
        case .unknown: throw SafetyError("当前模式尚未确认，未查询额度。")
        }
        guard current == name, try confirmedCurrentProfile() == name,
              protection.desktopScope == scope, DesktopModeInspector.read(support: support) == scope,
              profiles.first(where: { $0.name == name })?.snapshot?.identity.samePrincipal(as: identity) == true else {
            throw SafetyError("当前订阅身份未匹配，未改写额度。")
        }
        return QuietUsageContext(profile: name, identity: identity, access: access, scope: scope)
    }

    /// Test seams are mandatory in demo mode: no real login, guard or network access.
    func refreshQuietUsage(context: (() async throws -> QuietUsageContext)? = nil,
                           gate: (() async -> Bool)? = nil,
                           fetch: ((String) async throws -> Data)? = nil,
                           now: () -> Date = Date.init) async throws {
        guard !isDemo || (context != nil && gate != nil && fetch != nil) else { throw SafetyError("演示模式不读取真实登录。") }
        let read = context ?? { try await self.quietUsageContext() }
        let before = try await read()
        guard before.profile == current, before.scope == protection.desktopScope, before.identity.isComplete,
              active?.snapshot?.identity.samePrincipal(as: before.identity) == true else { throw SafetyError("账号已变化，未查询额度。") }
        let permitted = await (gate ?? { await self.protection.preflight(target: .subscriptionUsage).allowed })()
        guard permitted else { throw SafetyError("网络检查未通过，保留原额度。") }
        // Authorization and network checking may take time. Rebind immediately before sending.
        guard try await read() == before else { throw SafetyError("登录在检查期间变化，未查询额度。") }
        let data = try await (fetch ?? QuietUsageHTTP.read)(before.access)
        let sample = try SubscriptionUsageSample.read(data)
        guard try await read() == before, current == before.profile,
              protection.desktopScope == before.scope,
              var snapshot = active?.snapshot, snapshot.identity.samePrincipal(as: before.identity) else {
            throw SafetyError("查询期间订阅账号已变化，未采纳旧额度。")
        }
        snapshot.session = sample.session.map { Window(used: $0.used, resetsAt: $0.resetsAt) }
        snapshot.weekly = sample.weekly.map { Window(used: $0.used, resetsAt: $0.resetsAt) }
        snapshot.weeklyOpus = sample.weeklyOpus.map { Window(used: $0.used, resetsAt: $0.resetsAt) }
        snapshot.fetchedAt = now()
        acceptSubscriptionUsageResult(.success(snapshot), for: before.profile, contextUnchanged: true)
        usageNotice = nil
    }
}
