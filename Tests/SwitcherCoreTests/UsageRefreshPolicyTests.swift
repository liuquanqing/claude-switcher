import XCTest
@testable import SwitcherCore

final class UsageRefreshPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testActiveAndIdleCadences() {
        let policy = UsageRefreshPolicy()
        func due(_ age: Double, _ active: Bool) -> Bool {
            policy.shouldRequest(profile: "A", sampledAt: now.addingTimeInterval(-age), resetsAt: [], active: active, trigger: .periodic, now: now)
        }
        XCTAssertFalse(due(299, true)); XCTAssertTrue(due(300, true))
        XCTAssertFalse(due(899, false)); XCTAssertTrue(due(900, false))
        XCTAssertFalse(due(-60, true))
    }
    func testEventsCoalesceAndAccountChangeGetsFreshRead() {
        var policy = UsageRefreshPolicy()
        for trigger in [UsageRefreshPolicy.Trigger.periodic, .panel, .wake] {
            XCTAssertFalse(policy.shouldRequest(profile: "A", sampledAt: now, resetsAt: [], active: true, trigger: trigger, now: now))
        }
        XCTAssertTrue(policy.shouldRequest(profile: "A", sampledAt: now, resetsAt: [], active: true, trigger: .identityChanged, now: now))
        policy.began(profile: "A", now: now)
        XCTAssertFalse(policy.shouldRequest(profile: "A", sampledAt: nil, resetsAt: [], active: true, trigger: .identityChanged, now: now.addingTimeInterval(59)))
        XCTAssertTrue(policy.shouldRequest(profile: "A", sampledAt: nil, resetsAt: [], active: true, trigger: .identityChanged, now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldRequest(profile: "B", sampledAt: nil, resetsAt: [], active: true, trigger: .panel, now: now))
    }
    func testFailureAndServerBackoff() {
        var policy = UsageRefreshPolicy()
        policy.failed(profile: "A", now: now)
        XCTAssertFalse(policy.shouldRequest(profile: "A", sampledAt: nil, resetsAt: [], active: true, trigger: .wake, now: now.addingTimeInterval(299)))
        XCTAssertTrue(policy.shouldRequest(profile: "A", sampledAt: nil, resetsAt: [], active: true, trigger: .periodic, now: now.addingTimeInterval(300)))
        policy.failed(profile: "A", now: now, retryAfter: now.addingTimeInterval(1800))
        XCTAssertFalse(policy.shouldRequest(profile: "A", sampledAt: nil, resetsAt: [], active: true, trigger: .identityChanged, now: now.addingTimeInterval(1799)))
        XCTAssertTrue(policy.shouldRequest(profile: "A", sampledAt: nil, resetsAt: [], active: true, trigger: .periodic, now: now.addingTimeInterval(1800)))
    }
    func testResetNeedsServerReadWithoutBusyLoop() {
        var policy = UsageRefreshPolicy()
        let sample = now.addingTimeInterval(-100), reset = now.addingTimeInterval(-1)
        XCTAssertTrue(policy.shouldRequest(profile: "A", sampledAt: sample, resetsAt: [reset], active: true, trigger: .periodic, now: now))
        policy.began(profile: "A", now: now)
        XCTAssertFalse(policy.shouldRequest(profile: "A", sampledAt: sample, resetsAt: [reset], active: true, trigger: .periodic, now: now.addingTimeInterval(15)))
        // A successfully sampled already-expired reset is not requested on every tick.
        XCTAssertFalse(policy.shouldRequest(profile: "A", sampledAt: now, resetsAt: [reset], active: true, trigger: .periodic, now: now.addingTimeInterval(61)))
    }
    func testUsageParserWeeklyOnlyAndZeroAreValid() throws {
        let sample = try SubscriptionUsageSample.read(Data(#"{"five_hour":null,"seven_day":{"utilization":0,"resets_at":null}}"#.utf8))
        XCTAssertNil(sample.session); XCTAssertEqual(sample.weekly?.used, 0); XCTAssertNil(sample.weekly?.resetsAt)
        let dated = try SubscriptionUsageSample.read(Data(#"{"five_hour":{"utilization":100,"resets_at":"2026-11-01T00:00:00.123Z"}}"#.utf8))
        XCTAssertEqual(dated.session?.used, 100); XCTAssertNotNil(dated.session?.resetsAt)
    }
    func testMalformedSamplesNeverBecomeFresh() {
        for json in ["{}", #"{"five_hour":{"utilization":true}}"#, #"{"five_hour":{"utilization":101}}"#,
                     #"{"seven_day":{"utilization":-1}}"#, #"{"seven_day":{"utilization":10,"resets_at":"wrong"}}"#,
                     #"{"seven_day":{"utilization":"10"}}"#, "[]"] {
            XCTAssertThrowsError(try SubscriptionUsageSample.read(Data(json.utf8)), json)
        }
    }
}
