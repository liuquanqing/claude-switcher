import XCTest
@testable import SwitcherCore

final class CLIBindingTests: FixtureTest {
    func testBindingOnlyWritesOwnedMetadataAndIdentityIsNotTheFolderName() throws {
        let home = try directory("home"), a = CLIIdentity(accountID: "A", organizationID: "O", email: "a@example.invalid")
        let original = try directory("home/.claude")
        let history = original.appendingPathComponent("history.jsonl")
        try Data("fictional history".utf8).write(to: history)
        let repository = CLIBindingRepository(file: home.appendingPathComponent("switcher/bindings.json"), home: home)
        let binding = CLIBinding(identity: a, choice: .defaultLogin, directory: original)
        try repository.save(binding)
        XCTAssertEqual(try repository.load(a), binding)
        XCTAssertNil(try repository.load(CLIIdentity(accountID: "A", organizationID: "other", email: a.email)))
        XCTAssertEqual(try Data(contentsOf: history), Data("fictional history".utf8))
        let isolated = try CLIBinding.directory(for: .isolated, identity: a, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.path), "choosing a path does not create or copy a login")
    }
    func testReportedIdentityAndDirectoryMustBothMatch() throws {
        let identity = CLIIdentity(accountID: "A", organizationID: "O", email: "a@example.invalid")
        let binding = CLIBinding(identity: identity, choice: .defaultLogin, directory: URL(fileURLWithPath: "/fixture/.claude"))
        func report(_ account: String = "A", org: String = "O", dir: String = "/fixture/.claude") throws -> CLIReportedStatus {
            try CLIReportedStatus(data: CLIJSON.encode(["loggedIn": true, "authMethod": "claude.ai", "configDirectory": dir, "accountId": account, "orgId": org]))
        }
        XCTAssertEqual(CLIBindingPolicy.assess(try report(), binding: binding, metadata: nil), .matched)
        XCTAssertEqual(CLIBindingPolicy.assess(try report("B"), binding: binding, metadata: nil), .different)
        XCTAssertEqual(CLIBindingPolicy.assess(try report(org: "other"), binding: binding, metadata: nil), .different)
        XCTAssertEqual(CLIBindingPolicy.assess(try report(dir: "/other/.claude"), binding: binding, metadata: nil), .unconfirmed)
        let onlyEmail = try CLIReportedStatus(data: CLIJSON.encode(["loggedIn": true, "authMethod": "claude.ai", "configDirectory": binding.directory.path, "email": "a@example.invalid"]))
        XCTAssertEqual(CLIBindingPolicy.assess(onlyEmail, binding: binding, metadata: nil), .unconfirmed)
    }
    func testLocalRecordFollowsTheDesktopAccountWithoutClaimingVerification() {
        let a = CLIIdentity(accountID: "A", organizationID: "O", email: "a@example.invalid")
        let b = CLIIdentity(accountID: "B", organizationID: "O", email: "b@example.invalid")
        XCTAssertEqual(CLILocalRecordPolicy.assess(binding: nil, bindingMetadata: nil, defaultMetadata: a,
                                                   isolatedMetadata: nil, expected: a), .sameAccount(.defaultLogin))
        XCTAssertEqual(CLILocalRecordPolicy.assess(binding: nil, bindingMetadata: nil, defaultMetadata: a,
                                                   isolatedMetadata: b, expected: b), .sameAccount(.isolated))
        XCTAssertEqual(CLILocalRecordPolicy.assess(binding: nil, bindingMetadata: nil, defaultMetadata: a,
                                                   isolatedMetadata: nil, expected: b), .differentAccount)
        XCTAssertEqual(CLILocalRecordPolicy.assess(binding: nil, bindingMetadata: nil, defaultMetadata: nil,
                                                   isolatedMetadata: nil, expected: b), .notPrepared)
    }
    func testIncompleteOrUnexpectedRecordsStayUnconfirmed() {
        let expected = CLIIdentity(accountID: "A", organizationID: "O", email: "a@example.invalid")
        let incomplete = CLIIdentity(accountID: "A", organizationID: nil, email: "a@example.invalid")
        let other = CLIIdentity(accountID: "B", organizationID: "O", email: "b@example.invalid")
        let binding = CLIBinding(identity: other, choice: .isolated, directory: URL(fileURLWithPath: "/fixture/B"))
        XCTAssertEqual(CLILocalRecordPolicy.assess(binding: nil, bindingMetadata: nil, defaultMetadata: incomplete,
                                                   isolatedMetadata: nil, expected: expected), .unconfirmed)
        XCTAssertEqual(CLILocalRecordPolicy.assess(binding: binding, bindingMetadata: expected, defaultMetadata: nil,
                                                   isolatedMetadata: nil, expected: expected), .unconfirmed)
        XCTAssertEqual(CLILocalRecordPolicy.assess(binding: nil, bindingMetadata: nil, defaultMetadata: nil,
                                                   isolatedMetadata: other, expected: expected), .differentAccount)
    }
}
