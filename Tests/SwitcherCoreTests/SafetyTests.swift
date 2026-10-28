import XCTest
@testable import SwitcherCore

final class SafetyTests: XCTestCase {
    let config = SafetyConfig(enabled: true)
    let good = NetworkObservation(proxyConnected: true, tunOnline: true, country: "SG")

    func testConfigurationNormalizesAndRejectsInvalidCountries() throws {
        XCTAssertEqual(try SafetyConfig(expectedCountry: " sg ").validated().expectedCountry, "SG")
        for country in ["", "S", "SGP", "S1", "新加", "S\nG", "ZZ", "AA"] {
            XCTAssertThrowsError(try SafetyConfig(expectedCountry: country).validated())
        }
    }
    func testHardFailuresAndUnknownCountryCannotPass() {
        XCTAssertTrue(SafetyPolicy.evaluate(config, good).allowed)
        for (observation, reason) in [
            (NetworkObservation(proxyConnected: false, tunOnline: true, country: "SG"), SafetyReason.proxyDisconnected),
            (NetworkObservation(proxyConnected: true, tunOnline: false, country: "SG"), .tunMissing),
            (NetworkObservation(proxyConnected: true, tunOnline: true, country: nil), .countryUnknown),
            (NetworkObservation(proxyConnected: true, tunOnline: true, country: "sg"), .countryUnknown),
            (NetworkObservation(proxyConnected: true, tunOnline: true, country: "JP"), .countryMismatch)
        ] { XCTAssertEqual(SafetyPolicy.evaluate(config, observation).reason, reason) }
        XCTAssertEqual(SafetyPolicy.evaluate(SafetyConfig(), good).reason, .disabled)
    }
    func testTraceCannotUseErrorPagesDuplicatesOrInvalidValues() {
        XCTAssertEqual(NetworkObservation.countryFromTrace("ip=203.0.113.1\nloc=SG\n", httpStatus: 200), "SG")
        for (text, code) in [("loc=SG", 403), ("loc=SG\nloc=JP", 200), ("loc=", 200), ("loc=sg", 200), ("<html>error</html>", 200)] {
            XCTAssertNil(NetworkObservation.countryFromTrace(text, httpStatus: code))
        }
    }
    func testOtherVPNAndInet6DoNotSatisfyRequiredConnection() {
        XCTAssertFalse(NetworkObservation.shadowrocketConnected("(Connected) other-vpn\n(Disconnected) com.liguangming.Shadowrocket"))
        XCTAssertTrue(NetworkObservation.shadowrocketConnected("(Connected) com.liguangming.Shadowrocket"))
        XCTAssertFalse(NetworkObservation.hasSupportedTUN("inet6 198.18.0.1\ninet 192.0.2.1"))
        XCTAssertTrue(NetworkObservation.hasSupportedTUN("\tinet 198.18.0.1 netmask 0xffff0000"))
    }
    func testEveryClaudeRouteMustReturnSameKnownCountry() {
        XCTAssertEqual(NetworkObservation.sharedCountry(["SG", "SG", "SG"]), "SG")
        XCTAssertNil(NetworkObservation.sharedCountry(["SG", nil, "SG"]))
        XCTAssertNil(NetworkObservation.sharedCountry(["SG", "JP", "SG"]))
        XCTAssertNil(NetworkObservation.sharedCountry([]))
    }
    func testSplitClaudeRoutesCannotPassEvenIfReferenceCountryMatches() {
        let observation = NetworkObservation(proxyConnected: true, tunOnline: true, country: "SG", routesDisagree: true)
        XCTAssertEqual(SafetyPolicy.evaluate(config, observation).reason, .routesDisagree)
    }
    func testFreshReceiptMustMatchPolicyAndClock() {
        let now = Date(), receipt = GuardReceipt(checkedAt: Date(), config: config, decision: SafetyDecision(.allowed))
        XCTAssertTrue(receipt.isFresh(for: config, now: now.addingTimeInterval(1)))
        XCTAssertFalse(receipt.isFresh(for: config, now: now.addingTimeInterval(40)))
        XCTAssertFalse(receipt.isFresh(for: config, now: now.addingTimeInterval(-5)))
        XCTAssertFalse(receipt.isFresh(for: SafetyConfig(enabled: true, expectedCountry: "JP")))
    }
    func testLiveGateRequiresRegisteredFreshGuardAndFreshNetwork() {
        let receipt = GuardReceipt(config: config, decision: SafetyDecision(.allowed))
        XCTAssertEqual(LaunchGate.evaluate(config: config, registered: false, receipt: receipt, network: good).reason, .guardUnavailable)
        XCTAssertEqual(LaunchGate.evaluate(config: config, registered: true, receipt: nil, network: good).reason, .staleReceipt)
        XCTAssertEqual(LaunchGate.evaluate(config: config, registered: true, receipt: receipt,
                                          network: NetworkObservation(proxyConnected: true, tunOnline: true, country: "JP")).reason, .countryMismatch)
        XCTAssertTrue(LaunchGate.evaluate(config: config, registered: true, receipt: receipt, network: good).allowed)
    }
    func testDeniedGateHasNoAccountOrLaunchSideEffects() async {
        var prepared = false, launched = false
        do {
            try await LaunchGate.run(check: { SafetyDecision(.countryUnknown) },
                                     prepare: { prepared = true }, launch: { launched = true })
            XCTFail("unknown country should block")
        } catch {}
        XCTAssertFalse(prepared); XCTAssertFalse(launched)
    }
    func testCountryChangeDuringSwitchBlocksReopen() async {
        var checks = 0, prepared = false, launched = false
        do {
            try await LaunchGate.run(check: {
                checks += 1; return SafetyDecision(checks == 1 ? .allowed : .countryMismatch)
            }, prepare: { prepared = true }, launch: { launched = true })
            XCTFail("second check must block")
        } catch {}
        XCTAssertEqual(checks, 2); XCTAssertTrue(prepared); XCTAssertFalse(launched)
    }
    func testPreparationFailureNeverLaunches() async {
        var checks = 0, launched = false
        do {
            try await LaunchGate.run(check: { checks += 1; return SafetyDecision(.allowed) },
                                     prepare: { throw SafetyError("disk full") }, launch: { launched = true })
            XCTFail("prepare must fail")
        } catch {}
        XCTAssertEqual(checks, 1); XCTAssertFalse(launched)
    }
    func testLaunchFailureIsNotReportedAsSuccess() async {
        do {
            try await LaunchGate.run(check: { SafetyDecision(.allowed) }, prepare: {},
                                     launch: { throw SafetyError("application missing") })
            XCTFail("launch error must propagate")
        } catch { XCTAssertTrue(error.localizedDescription.contains("application missing")) }
    }
    func testGuardStopsOnMismatchAndUnknownButNeverWhenDisabled() async {
        var stops = 0
        let action: () async -> String = { stops += 1; return "closed" }
        _ = await GuardEngine.tick(config: config, network: good, stop: action)
        XCTAssertEqual(stops, 0)
        _ = await GuardEngine.tick(config: config, network: NetworkObservation(proxyConnected: true, tunOnline: true, country: nil), stop: action)
        _ = await GuardEngine.tick(config: config, network: NetworkObservation(proxyConnected: true, tunOnline: true, country: "JP"), stop: action)
        XCTAssertEqual(stops, 2)
        _ = await GuardEngine.tick(config: SafetyConfig(), network: good, stop: action)
        XCTAssertEqual(stops, 2)
    }
    func testReceiptStoresDecisionAndFailedStopWithoutAddressOrSecrets() async throws {
        let receipt = await GuardEngine.tick(config: config,
            network: NetworkObservation(proxyConnected: false, tunOnline: false, country: nil), stop: { "failed" })
        XCTAssertEqual(receipt.termination, "failed")
        XCTAssertFalse(receipt.decision.allowed)
        let text = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertFalse(text.contains("ip=")); XCTAssertFalse(text.contains("token")); XCTAssertFalse(text.contains("203.0.113"))
    }
}
