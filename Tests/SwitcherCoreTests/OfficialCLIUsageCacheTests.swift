import XCTest
@testable import SwitcherCore

final class OfficialCLIUsageCacheTests: XCTestCase {
    func document(account: String = "fixture-a", cacheAccount: String = "fixture-a", sampled: Any = 1_700_000_000_000,
                  used: Any = 23, reset: Any = "2026-01-03T09:00:00Z") throws -> Data {
        try CLIJSON.encode([
            "oauthAccount": ["accountUuid": account, "organizationUuid": "fixture-org", "emailAddress": "fixture@example.test"],
            "cachedUsageUtilization": ["accountUuid": cacheAccount, "fetchedAtMs": sampled,
                "utilization": ["five_hour": ["utilization": used, "resets_at": reset],
                                "seven_day": ["utilization": 51, "resets_at": NSNull()]]]
        ])
    }
    func testReadsOriginalTimestampAndSeparateWindows() throws {
        let sample = try XCTUnwrap(OfficialCLIUsageCache.read(document()))
        XCTAssertEqual(sample.identity.accountID, "fixture-a")
        XCTAssertEqual(sample.identity.organizationID, "fixture-org")
        XCTAssertEqual(sample.fetchedAt.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(sample.session?.used, 23)
        XCTAssertEqual(sample.weekly?.used, 51)
        XCTAssertNil(sample.weekly?.resetsAt)
        XCTAssertNil(sample.weeklyOpus)
    }
    func testNeverAttributesAnotherAccountsCache() throws {
        XCTAssertThrowsError(try OfficialCLIUsageCache.read(document(cacheAccount: "another-account")))
    }
    func testRejectsMalformedNumbersWithoutInventingData() throws {
        for used: Any in [true, -1, 101, "23"] {
            XCTAssertThrowsError(try OfficialCLIUsageCache.read(document(used: used)))
        }
        for sampled: Any in [false, -1, "1700000000000"] {
            XCTAssertThrowsError(try OfficialCLIUsageCache.read(document(sampled: sampled)))
        }
    }
    func testMissingNativeCacheIsUnavailableNotZeroUsage() throws {
        let data = try CLIJSON.encode(["oauthAccount": ["accountUuid": "fixture-a", "organizationUuid": "fixture-org"]])
        XCTAssertNil(try OfficialCLIUsageCache.read(data))
        XCTAssertNil(try OfficialCLIUsageCache.read(CLIJSON.encode([:])))
    }
    func testKeepsPastServerDatesAndAcceptsFractions() throws {
        let past = try XCTUnwrap(OfficialCLIUsageCache.read(document(reset: "2020-01-03T09:00:00Z")))
        XCTAssertEqual(past.session?.resetsAt, ISO8601DateFormatter().date(from: "2020-01-03T09:00:00Z"))
        XCTAssertEqual(past.session?.used, 23)
        XCTAssertNotNil(try OfficialCLIUsageCache.read(document(reset: "2026-01-03T09:00:00.123Z"))?.session?.resetsAt)
        XCTAssertThrowsError(try OfficialCLIUsageCache.read(document(reset: "Friday afternoon")))
    }
    func testAccountNormalizationNeverUsesEmailAsIdentity() throws {
        let data = try CLIJSON.encode(["oauthAccount": ["emailAddress": "same@example.test"],
            "cachedUsageUtilization": ["accountUuid": "fixture-a", "fetchedAtMs": 1_700_000_000_000,
                "utilization": ["five_hour": ["utilization": 0]]]])
        XCTAssertNil(try OfficialCLIUsageCache.read(data))
    }
}
