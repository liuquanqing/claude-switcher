import XCTest
@testable import SwitcherCore

final class CLIReportedStatusTests: XCTestCase {
    func report(_ extras: [String: Any] = [:]) throws -> CLIReportedStatus {
        var value: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai", "configDirectory": "/fixture/.claude",
            "email": "fixture@example.test", "orgId": "org-one"]
        extras.forEach { value[$0.key] = $0.value }
        return try CLIReportedStatus(data: CLIJSON.encode(value))
    }
    func testLocalReportCanBeReadWithoutCredentialValues() throws {
        let value = try report()
        XCTAssertTrue(value.loggedIn); XCTAssertEqual(value.authMethod, "claude.ai")
        XCTAssertTrue(value.usesConfigurationDirectory(URL(fileURLWithPath: "/fixture/.claude")))
        XCTAssertFalse(value.identity.isComplete)
    }
    func testMetadataAccountIsBorrowedOnlyWhenEmailAndOrganizationAgree() throws {
        let value = try report(), metadata = CLIIdentity(accountID: "account-one", organizationID: "org-one", email: "fixture@example.test")
        XCTAssertTrue(value.savedRecord(matching: metadata)?.samePrincipal(as: metadata) == true)
        XCTAssertFalse(value.savedRecord(matching: .init(accountID: "wrong", organizationID: "org-other", email: metadata.email))?.isComplete == true)
        XCTAssertFalse(value.savedRecord(matching: .init(accountID: "wrong", organizationID: metadata.organizationID, email: "other@example.test"))?.isComplete == true)
    }
    func testLoggedOutOrOtherAuthenticationCannotClaimSubscriptionIdentity() throws {
        let metadata = CLIIdentity(accountID: "account-one", organizationID: "org-one", email: "fixture@example.test")
        XCTAssertNil(try report(["loggedIn": false, "authMethod": "none"]).savedRecord(matching: metadata))
        XCTAssertNil(try report(["authMethod": "api_key"]).savedRecord(matching: metadata))
    }
    func testAccountOnlyMatchDoesNotBecomeCompletePrincipalMatch() throws {
        let full = CLIIdentity(accountID: "a", organizationID: "org", email: nil)
        let partial = CLIIdentity(accountID: "a", organizationID: nil, email: nil)
        XCTAssertEqual(CLIReportedStatus.sameAccountRecord(full, partial), true)
        XCTAssertFalse(full.samePrincipal(as: partial))
        XCTAssertNil(CLIReportedStatus.sameAccountRecord(full, nil))
        XCTAssertEqual(CLIReportedStatus.sameAccountRecord(.init(accountID: "opaqueA", organizationID: nil, email: nil), .init(accountID: "opaquea", organizationID: nil, email: nil)), false)
    }
    func testMalformedOrConflictingReportsRemainUnknown() throws {
        for extras: [String: Any] in [["loggedIn": 1], ["authMethod": "future-mode"], ["configDirectory": "relative"], ["organizationUuid": "other"], ["email": 7]] {
            XCTAssertThrowsError(try report(extras))
        }
    }
    func testCustomDirectoryDoesNotMatchDefaultNamespace() throws {
        let value = try report(["configDirectory": "/fixture/other"])
        XCTAssertFalse(value.usesConfigurationDirectory(URL(fileURLWithPath: "/fixture/.claude")))
    }
}
