import XCTest
@testable import SwitcherCore

final class DesktopOnlyFlowTests: FixtureTest {
    private func fixture(markerWriter: ((Data, URL) throws -> Void)? = nil) throws -> (ProfileTransaction, URL, URL, URL) {
        let live = try directory("live"), parked = try directory("parked"), target = try directory("parked/B")
        let marker = parked.appendingPathComponent(".current")
        try Data("A".utf8).write(to: live.appendingPathComponent("data"))
        try Data("B".utf8).write(to: target.appendingPathComponent("data"))
        try Data("A".utf8).write(to: marker)
        let tx = ProfileTransaction(live: live, parked: parked, marker: marker,
                                   writeMarker: markerWriter ?? { try $0.write(to: $1, options: .atomic) })
        return (tx, live, parked, marker)
    }
    @MainActor func testDeniedGateCannotQuitOrMove() async throws {
        let (tx, live, _, marker) = try fixture(); var quit = false
        do {
            try await DesktopOnlyFlow.run(transaction: tx, from: "A", to: "B", current: { try ProfileTransaction.currentName(at: marker) },
                subscriptionMode: { true }, quit: { quit = true; return true }, check: { SafetyDecision(.countryUnknown) }, launch: { XCTFail("launch") })
            XCTFail("blocked")
        } catch let error as DesktopOnlyFailure { XCTAssertEqual(error.directoryChanged, false) }
        XCTAssertFalse(quit); XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("data")), "A")
    }
    @MainActor func testAPITargetCannotQuitOrMove() async throws {
        let (tx, live, _, marker) = try fixture(); var quit = false
        do {
            try await DesktopOnlyFlow.run(transaction: tx, from: "A", to: "B", current: { try ProfileTransaction.currentName(at: marker) },
                subscriptionMode: { false }, quit: { quit = true; return true }, check: { SafetyDecision(.allowed) }, launch: { XCTFail("launch") })
            XCTFail("API target")
        } catch let error as DesktopOnlyFailure { XCTAssertEqual(error.directoryChanged, false) }
        XCTAssertFalse(quit); XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("data")), "A")
    }
    @MainActor func testModeChangesAfterQuitDoNotMove() async throws {
        let (tx, live, _, marker) = try fixture(); var subscription = true
        do {
            try await DesktopOnlyFlow.run(transaction: tx, from: "A", to: "B", current: { try ProfileTransaction.currentName(at: marker) },
                subscriptionMode: { subscription }, quit: { subscription = false; return true }, check: { SafetyDecision(.allowed) }, launch: { XCTFail("launch") })
            XCTFail("mode changed")
        } catch let error as DesktopOnlyFailure { XCTAssertEqual(error.directoryChanged, false) }
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("data")), "A")
    }
    @MainActor func testSecondGateFailureReportsCompletedMoveWithoutLaunch() async throws {
        let (tx, live, _, marker) = try fixture(); var checks = 0
        do {
            try await DesktopOnlyFlow.run(transaction: tx, from: "A", to: "B", current: { try ProfileTransaction.currentName(at: marker) },
                subscriptionMode: { true }, quit: { true }, check: { checks += 1; return SafetyDecision(checks == 1 ? .allowed : .countryUnknown) }, launch: { XCTFail("launch") })
            XCTFail("second gate")
        } catch let error as DesktopOnlyFailure { XCTAssertEqual(error.directoryChanged, true) }
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("data")), "B")
        XCTAssertEqual(try ProfileTransaction.currentName(at: marker), "B")
    }
    @MainActor func testFailedMoveKeepsNativeRollbackAndDoesNotClaimUnchanged() async throws {
        let (tx, live, _, marker) = try fixture(markerWriter: { _, _ in throw SafetyError("fixture marker write denied") })
        do {
            try await DesktopOnlyFlow.run(transaction: tx, from: "A", to: "B", current: { try ProfileTransaction.currentName(at: marker) },
                subscriptionMode: { true }, quit: { true }, check: { SafetyDecision(.allowed) }, launch: { XCTFail("launch") })
            XCTFail("write failed")
        } catch let error as DesktopOnlyFailure { XCTAssertNil(error.directoryChanged) }
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("data")), "A")
        XCTAssertEqual(try ProfileTransaction.currentName(at: marker), "A")
    }
    @MainActor func testSuccessfulFlowPreservesIndependentCLISentinel() async throws {
        let (tx, live, _, marker) = try fixture(); var launched = false
        let cli = folder.appendingPathComponent("independent-cli-fixture")
        let original = Data("fixture default login remains A".utf8); try original.write(to: cli)
        try await DesktopOnlyFlow.run(transaction: tx, from: "A", to: "B", current: { try ProfileTransaction.currentName(at: marker) },
            subscriptionMode: { true }, quit: { true }, check: { SafetyDecision(.allowed) }, launch: { launched = true })
        XCTAssertTrue(launched); XCTAssertEqual(try Data(contentsOf: cli), original)
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("data")), "B")
    }
}
