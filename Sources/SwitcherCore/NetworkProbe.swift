import Foundation
import OSLog

public enum LocalCommand {
    public static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public struct NetworkProbe {
    public static let traceEndpoints = ["https://claude.ai/cdn-cgi/trace",
                                        "https://api.anthropic.com/cdn-cgi/trace",
                                        "https://claude.com/cdn-cgi/trace"]
    enum TraceResult: Equatable, Sendable {
        case country(String), timedOut, unavailable

        var country: String? {
            if case .country(let value) = self { return value }
            return nil
        }
    }

    typealias Link = (proxyConnected: Bool?, tunOnline: Bool?)
    typealias Trace = @Sendable (String, URLSession) async -> TraceResult
    private static let log = Logger(subsystem: "dev.claudeswitcher", category: "network-probe")
    private let readLink: (ProxyMode) -> Link
    private let trace: Trace

    public init() {
        self.init(readLink: Self.currentLink, trace: { await Self.fetchTrace($0, session: $1) })
    }

    init(readLink: @escaping (ProxyMode) -> Link, trace: @escaping Trace) {
        self.readLink = readLink
        self.trace = trace
    }

    private static func currentLink(_ mode: ProxyMode) -> Link {
        func output(_ executable: String, _ arguments: [String]) -> String? {
            guard let (status, text) = try? LocalCommand.run(executable, arguments),
                  status == 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let tun = output("/sbin/ifconfig", []).map(NetworkObservation.hasSupportedTUN)
        let vpn = mode == .auto ? tun : output("/usr/sbin/scutil", ["--nc", "list"]).map(NetworkObservation.shadowrocketConnected)
        return (vpn, tun)
    }

    private static func observation(link: Link, countries: [String?]) -> NetworkObservation {
        let known = Set(countries.compactMap { $0 })
        let complete = NetworkObservation.sharedCountry(countries)
        return NetworkObservation(proxyConnected: link.proxyConnected == true, tunOnline: link.tunOnline == true,
                                  country: complete, routesDisagree: known.count > 1,
                                  partialCountry: complete == nil && known.count == 1 ? known.first : nil,
                                  proxyStatusUnconfirmed: link.proxyConnected == nil ? true : nil,
                                  tunStatusUnconfirmed: link.tunOnline == nil ? true : nil)
    }

    private static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }

    private static func fetchTrace(_ endpoint: String, session: URLSession) async -> TraceResult {
        guard let url = URL(string: endpoint) else { return .unavailable }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  let country = NetworkObservation.countryFromTrace(String(decoding: data, as: UTF8.self),
                                                                     httpStatus: http.statusCode) else { return .unavailable }
            return .country(country)
        } catch let error as URLError where error.code == .timedOut {
            return .timedOut
        } catch {
            return .unavailable
        }
    }

    public func observe(mode: ProxyMode, retrySingleTimeoutFor expectedCountry: String? = nil) async -> NetworkObservation {
        var link = readLink(mode)
        guard link.proxyConnected == true, link.tunOnline == true else {
            return Self.observation(link: link, countries: [])
        }
        let session = Self.makeSession(requestTimeout: 6, resourceTimeout: 8)
        defer { session.invalidateAndCancel() }
        var results = await withTaskGroup(of: (String, TraceResult).self, returning: [(String, TraceResult)].self) { group in
            for endpoint in Self.traceEndpoints {
                group.addTask { [trace] in (endpoint, await trace(endpoint, session)) }
            }
            var values: [(String, TraceResult)] = []
            for await value in group { values.append(value) }
            return values
        }
        link = readLink(mode)
        let timeouts = results.indices.filter { results[$0].1 == .timedOut }
        if let expectedCountry, link.proxyConnected == true, link.tunOnline == true, timeouts.count == 1,
           let index = timeouts.first,
           results.indices.allSatisfy({ $0 == index || results[$0].1 == .country(expectedCountry) }) {
            let endpoint = results[index].0
            let retrySession = Self.makeSession(requestTimeout: 3, resourceTimeout: 3)
            defer { retrySession.invalidateAndCancel() }
            let retry = await trace(endpoint, retrySession)
            results[index].1 = retry
            link = readLink(mode)
            let host = URL(string: endpoint)?.host ?? "unknown"
            let outcome = retry.country ?? (retry == .timedOut ? "timeout" : "unconfirmed")
            Self.log.notice("Retested timed-out Claude route: \(host, privacy: .public); result: \(outcome, privacy: .public)")
        }
        return Self.observation(link: link, countries: results.map { $0.1.country })
    }
}
