import XCTest
@testable import SwitcherCore

final class IdentityTests: XCTestCase {
    func testKnownMatchingOwnerCanBeBackedUp() throws {
        XCTAssertNoThrow(try AccountIdentity.requireMatch(expected: "one@example.test", observed: "one@example.test"))
    }
    func testUnknownOwnersNeverPassIncludingTwoMissingValues() {
        for pair: (String?, String?) in [(nil, nil), ("one@example.test", nil), (nil, "one@example.test"), ("", "")] {
            XCTAssertThrowsError(try AccountIdentity.requireMatch(expected: pair.0, observed: pair.1))
        }
    }
    func testDifferentOwnerFailsWithoutIncludingPrivateEmailsInError() {
        do {
            try AccountIdentity.requireMatch(expected: "one@example.test", observed: "two@example.test")
            XCTFail("wrong owner must not be backed up")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("@"))
        }
    }
}
