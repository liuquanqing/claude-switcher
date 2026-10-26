import XCTest
@testable import SwitcherCore

final class ThreadTests: FixtureTest {
    let repository = ThreadRepository()
    func session(_ relative: String, identity: String = "session-one", extras: [String: Any] = [:]) throws -> URL {
        let url = folder.appendingPathComponent(relative)
        var json: [String: Any] = ["cliSessionId": identity, "sessionId": "desktop-one", "title": "Example", "cwd": "/demo/project", "lastActivityAt": 1000]
        extras.forEach { json[$0] = $1 }
        try writeJSON(json, url)
        return url
    }
    func destination() throws -> ThreadDestination {
        let profile = try directory("target")
        try writeJSON(["lastKnownAccountUuid": "account-b"], profile.appendingPathComponent("config.json"))
        _ = try directory("target/claude-code-sessions/account-b/org-a")
        return try XCTUnwrap(repository.destinations(profile).first)
    }
    func source(_ id: String = "session-one") throws -> [ThreadInfo] {
        _ = try session("source/claude-code-sessions/account-a/org-a/local_one.json", identity: id)
        return try repository.scan(folder.appendingPathComponent("source")).threads
    }
    func testScanTraversesAllAccountsAndOrganizationsWithDistinctSelectionIDs() throws {
        for path in ["account-a/org-a", "account-a/org-b", "account-b/org-a"] {
            _ = try session("source/claude-code-sessions/\(path)/local_same.json", identity: path)
        }
        try writeJSON(["title": "broken schema"], folder.appendingPathComponent("source/claude-code-sessions/account-b/org-a/local_bad.json"))
        let scan = try repository.scan(folder.appendingPathComponent("source"))
        XCTAssertEqual(scan.threads.count, 3)
        XCTAssertEqual(Set(scan.threads.map(\.id)).count, 3)
        XCTAssertEqual(scan.unreadable, 1)
    }
    func testDestinationUsesLastLoginAccountAndReturnsEveryOrganization() throws {
        let profile = try directory("target")
        for path in ["account-a/org-old", "account-b/org-one", "account-b/org-two"] {
            _ = try directory("target/claude-code-sessions/" + path)
        }
        try writeJSON(["lastKnownAccountUuid": "account-b"], profile.appendingPathComponent("config.json"))
        let destinations = try repository.destinations(profile)
        XCTAssertEqual(destinations.count, 2)
        XCTAssertTrue(destinations.allSatisfy { $0.account == "account-b" })
    }
    func testAmbiguousOrMissingLoginAccountCannotGuessDestination() throws {
        let profile = try directory("target")
        _ = try directory("target/claude-code-sessions/account-a/org-a")
        _ = try directory("target/claude-code-sessions/account-b/org-b")
        XCTAssertThrowsError(try repository.destinations(profile))
        try writeJSON(["lastKnownAccountUuid": "missing"], profile.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try repository.destinations(profile))
    }
    func testCopyPreservesNewSchemaAndSourceButRemovesAccountBoundFields() throws {
        let input = try session("source/claude-code-sessions/account-a/org-a/local_one.json", extras: [
            "spawnSeed": ["futureField": 42], "toolSurfaceSnapshot": ["future": true],
            "remoteMcpServersConfig": ["private-connector"], "bridgeSessionIds": ["old-bridge"],
            "armedWorkAtQuit": true, "remoteControlAutoEligible": true, "steeredByRemoteClient": true
        ])
        let original = try Data(contentsOf: input), dest = try destination()
        let threads = try repository.scan(folder.appendingPathComponent("source")).threads
        let result = try repository.copy(threads, to: dest)
        XCTAssertEqual(result.copied, 1)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dest.directory.appendingPathComponent(input.lastPathComponent))) as! [String: Any]
        XCTAssertEqual((json["spawnSeed"] as? [String: Int])?["futureField"], 42)
        XCTAssertNotNil(json["toolSurfaceSnapshot"])
        for key in ["remoteMcpServersConfig", "bridgeSessionIds", "armedWorkAtQuit", "remoteControlAutoEligible", "steeredByRemoteClient"] {
            XCTAssertNil(json[key])
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testExistingSameSessionIsSkippedByteForByte() throws {
        let input = try source(), dest = try destination()
        let file = dest.directory.appendingPathComponent("local_one.json")
        try writeJSON(["cliSessionId": "session-one", "newTargetField": "keep"], file)
        let before = try Data(contentsOf: file)
        let result = try repository.copy(input, to: dest)
        XCTAssertEqual(result.copied, 0); XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testDifferentExistingSessionCannotBeOverwritten() throws {
        let input = try source(), dest = try destination()
        let file = dest.directory.appendingPathComponent("local_one.json")
        try writeJSON(["cliSessionId": "different"], file)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try repository.copy(input, to: dest))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testSourceFilenameConflictsAreDetectedBeforeAnyWrite() throws {
        _ = try source()
        _ = try session("source/claude-code-sessions/account-a/org-b/local_one.json", identity: "different")
        let input = try repository.scan(folder.appendingPathComponent("source")).threads, dest = try destination()
        XCTAssertThrowsError(try repository.copy(input, to: dest))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dest.directory.path).isEmpty)
    }
    func testWriteFailureRemovesOnlyThisBatchAndLeavesSourceUntouched() throws {
        _ = try source()
        _ = try session("source/claude-code-sessions/account-a/org-a/local_two.json", identity: "session-two")
        let input = try repository.scan(folder.appendingPathComponent("source")).threads, dest = try destination()
        let keep = dest.directory.appendingPathComponent("existing.json")
        try Data("unique".utf8).write(to: keep)
        var writes = 0
        XCTAssertThrowsError(try repository.copy(input, to: dest, write: { data, output in
            writes += 1; try data.write(to: output)
            if writes == 2 { throw SafetyError("disk full") }
        }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.directory.path), ["existing.json"])
        XCTAssertEqual(try String(contentsOf: keep), "unique")
        XCTAssertEqual(try repository.scan(folder.appendingPathComponent("source")).threads.count, 2)
    }
    func testSymlinkSourceOrganizationIsNotFollowed() throws {
        _ = try session("outside/local_one.json")
        let account = try directory("source/claude-code-sessions/account-a")
        try FileManager.default.createSymbolicLink(at: account.appendingPathComponent("linked"), withDestinationURL: folder.appendingPathComponent("outside"))
        XCTAssertTrue(try repository.scan(folder.appendingPathComponent("source")).threads.isEmpty)
    }
    func testProjectUnderApplicationSupportIsNotSilentlyDropped() throws {
        _ = try session("source/claude-code-sessions/account-a/org-a/local_one.json", extras: ["cwd": "/demo/Library/Application Support/Other/project"])
        XCTAssertEqual(try repository.scan(folder.appendingPathComponent("source")).threads.count, 1)
    }
}
