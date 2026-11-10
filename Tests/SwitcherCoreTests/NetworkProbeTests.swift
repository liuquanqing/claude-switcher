import Foundation
import XCTest
@testable import SwitcherCore

final class NetworkProbeTests: XCTestCase {
    private actor Calls {
        struct Entry {
            let endpoint: String
            let resourceTimeout: TimeInterval
        }

        private(set) var entries: [Entry] = []

        func record(_ endpoint: String, resourceTimeout: TimeInterval) {
            entries.append(.init(endpoint: endpoint, resourceTimeout: resourceTimeout))
        }
    }

    private let config = SafetyConfig(enabled: true, expectedCountry: "SG")
    private let online: NetworkProbe.Link = (true, true)

    private func fixture(_ initial: [NetworkProbe.TraceResult], retry: NetworkProbe.TraceResult = .country("SG"),
                         links: [NetworkProbe.Link] = [(true, true)]) -> (NetworkProbe, Calls) {
        let responses = Dictionary(uniqueKeysWithValues: zip(NetworkProbe.traceEndpoints, initial))
        let calls = Calls()
        var check = 0
        let probe = NetworkProbe(readLink: { _ in
            defer { check += 1 }
            return links[min(check, links.count - 1)]
        }, trace: { endpoint, session in
            let timeout = session.configuration.timeoutIntervalForResource
            await calls.record(endpoint, resourceTimeout: timeout)
            return timeout == 3 ? retry : responses[endpoint] ?? .unavailable
        })
        return (probe, calls)
    }

    func testSingleTimedOutRouteIsRetestedOnceWithThreeSecondBudget() async {
        let (probe, calls) = fixture([.country("SG"), .timedOut, .country("SG")])
        let observation = await probe.observe(mode: .shadowrocket, retrySingleTimeoutFor: "SG")
        let entries = await calls.entries
        XCTAssertTrue(SafetyPolicy.evaluate(config, observation).allowed)
        XCTAssertEqual(entries.filter { $0.resourceTimeout == 8 }.count, 3)
        XCTAssertEqual(entries.filter { $0.resourceTimeout == 3 }.map(\.endpoint), [NetworkProbe.traceEndpoints[1]])
    }

    func testRegularLaunchProbeStillRequiresAllRoutesWithoutRetry() async {
        let (probe, calls) = fixture([.country("SG"), .timedOut, .country("SG")])
        let observation = await probe.observe(mode: .shadowrocket)
        let entries = await calls.entries
        XCTAssertEqual(SafetyPolicy.evaluate(config, observation).reason, .countryUnknown)
        XCTAssertEqual(entries.count, 3)
    }

    func testUnknownOrNonTargetResultsDoNotQualifyForRetry() async {
        let cases: [([NetworkProbe.TraceResult], SafetyReason)] = [
            ([.country("SG"), .timedOut, .timedOut], .countryUnknown),
            ([.country("SG"), .unavailable, .country("SG")], .countryUnknown),
            ([.country("SG"), .timedOut, .country("JP")], .routesDisagree),
            ([.country("JP"), .timedOut, .country("JP")], .countryMismatch),
            ([.timedOut, .country("JP"), .unavailable], .countryMismatch)
        ]
        for (results, reason) in cases {
            let (probe, calls) = fixture(results)
            let observation = await probe.observe(mode: .shadowrocket, retrySingleTimeoutFor: "SG")
            let entries = await calls.entries
            XCTAssertEqual(SafetyPolicy.evaluate(config, observation).reason, reason)
            XCTAssertEqual(entries.count, 3)
        }
    }

    func testRetryTimeoutOrDifferentCountryStillBlocks() async {
        let cases: [(NetworkProbe.TraceResult, SafetyReason)] = [
            (.timedOut, .countryUnknown), (.unavailable, .countryUnknown), (.country("JP"), .routesDisagree)
        ]
        for (retry, reason) in cases {
            let (probe, calls) = fixture([.timedOut, .country("SG"), .country("SG")], retry: retry)
            let observation = await probe.observe(mode: .shadowrocket, retrySingleTimeoutFor: "SG")
            let entries = await calls.entries
            XCTAssertEqual(SafetyPolicy.evaluate(config, observation).reason, reason)
            XCTAssertEqual(entries.filter { $0.resourceTimeout == 3 }.count, 1)
        }
    }

    func testLinkLossBeforeRetrySkipsItAndLinkLossDuringRetryCannotPass() async {
        let initial: [NetworkProbe.TraceResult] = [.country("SG"), .country("SG"), .timedOut]
        let (before, beforeCalls) = fixture(initial, links: [online, (false, true)])
        let disconnected = await before.observe(mode: .shadowrocket, retrySingleTimeoutFor: "SG")
        let beforeEntries = await beforeCalls.entries
        XCTAssertEqual(SafetyPolicy.evaluate(config, disconnected).reason, .proxyDisconnected)
        XCTAssertEqual(beforeEntries.count, 3)

        let (during, duringCalls) = fixture(initial, links: [online, online, (true, false)])
        let tunnelLost = await during.observe(mode: .shadowrocket, retrySingleTimeoutFor: "SG")
        let duringEntries = await duringCalls.entries
        XCTAssertEqual(SafetyPolicy.evaluate(config, tunnelLost).reason, .tunMissing)
        XCTAssertEqual(duringEntries.count, 4)
    }

    func testUnreadableLinkIsUnconfirmedAndNeverSendsProbes() async {
        let (probe, calls) = fixture([.country("SG"), .country("SG"), .country("SG")], links: [(nil, true)])
        let observation = await probe.observe(mode: .shadowrocket, retrySingleTimeoutFor: "SG")
        let entries = await calls.entries
        XCTAssertEqual(SafetyPolicy.evaluate(config, observation).reason, .linkUnknown)
        XCTAssertTrue(entries.isEmpty)
    }
}
