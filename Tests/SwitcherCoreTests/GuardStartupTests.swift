import Foundation
import XCTest
@testable import SwitcherCore

final class GuardStartupTests: XCTestCase {
    func testOldReceiptAndWrongConfigCannotConfirmANewStart() {
        let now = Date(), config = SafetyConfig(enabled: true)
        var receipt = GuardReceipt(checkedAt: now.addingTimeInterval(-1), config: config, decision: SafetyDecision(.allowed))
        receipt.supportsUnchangedModeMarker = true
        XCTAssertFalse(GuardStartup.accepts(receipt, config: config, startedAt: now, now: now))
        receipt.checkedAt = now
        XCTAssertTrue(GuardStartup.accepts(receipt, config: config, startedAt: now, now: now))
        XCTAssertFalse(GuardStartup.accepts(receipt, config: SafetyConfig(enabled: true, expectedCountry: "JP"), startedAt: now, now: now))
        receipt.supportsUnchangedModeMarker = nil
        XCTAssertFalse(GuardStartup.accepts(receipt, config: config, startedAt: now, now: now))
    }
    func testWaitingReachesFreshReplyWithoutOffOnDance() async throws {
        let start = Date(), config = SafetyConfig(enabled: true)
        var now = start, receipt: GuardReceipt?, sleeps = 0
        try await GuardStartup.wait(config: config, startedAt: start, receipt: { receipt }, stillEnabled: { true }, now: { now }, sleep: {
            sleeps += 1; now = now.addingTimeInterval(1)
            if sleeps == 2 {
                receipt = GuardReceipt(checkedAt: now, config: config, decision: SafetyDecision(.countryMismatch))
                receipt!.supportsUnchangedModeMarker = true
            }
        })
        XCTAssertEqual(sleeps, 2, "a fresh denied-network result is a live guard, not a startup failure")
    }
    func testTimeoutAndChangedIntentRemainUnknown() async {
        let start = Date(), config = SafetyConfig(enabled: true)
        var now = start
        do {
            try await GuardStartup.wait(config: config, startedAt: start, timeout: 1, receipt: { nil }, stillEnabled: { true }, now: { now }, sleep: { now = now.addingTimeInterval(1) })
            XCTFail("no receipt must not succeed")
        } catch { }
        do {
            try await GuardStartup.wait(config: config, startedAt: start, receipt: { nil }, stillEnabled: { false }, now: { start }, sleep: { XCTFail("do not keep waiting after pause") })
            XCTFail("changed intent must not succeed")
        } catch { }
    }
}
