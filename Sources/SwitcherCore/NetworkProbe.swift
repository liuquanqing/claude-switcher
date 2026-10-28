import Foundation

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
    public init() {}
    public func observe(mode: ProxyMode) async -> NetworkObservation {
        let interfaces = (try? LocalCommand.run("/sbin/ifconfig", []).1) ?? ""
        let tun = NetworkObservation.hasSupportedTUN(interfaces)
        let vpn = mode == .auto ? tun : NetworkObservation.shadowrocketConnected(
            (try? LocalCommand.run("/usr/sbin/scutil", ["--nc", "list"]).1) ?? "")
        // No probe is sent over a connection already known to be unprotected.
        guard vpn && tun else { return NetworkObservation(proxyConnected: vpn, tunOnline: tun, country: nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Probe the actual Claude routing domains, not an unrelated global proxy route.
        let countries = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for endpoint in Self.traceEndpoints {
                group.addTask {
                    guard let url = URL(string: endpoint),
                          let (data, response) = try? await session.data(from: url),
                          let http = response as? HTTPURLResponse else { return nil }
                    return NetworkObservation.countryFromTrace(String(decoding: data, as: UTF8.self), httpStatus: http.statusCode)
                }
            }
            var values: [String?] = []
            for await value in group { values.append(value) }
            return values
        }
        // Detect disconnects during the HTTPS request as well.
        let afterTUN = NetworkObservation.hasSupportedTUN((try? LocalCommand.run("/sbin/ifconfig", []).1) ?? "")
        let afterVPN = mode == .auto ? afterTUN : NetworkObservation.shadowrocketConnected(
            (try? LocalCommand.run("/usr/sbin/scutil", ["--nc", "list"]).1) ?? "")
        return NetworkObservation(proxyConnected: afterVPN, tunOnline: afterTUN,
                                  country: NetworkObservation.sharedCountry(countries),
                                  routesDisagree: Set(countries.compactMap { $0 }).count > 1)
    }
}
