import XCTest
@testable import SwitcherCore

class FixtureTest: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func directory(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func writeJSON(_ object: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}

final class ServiceTests: FixtureTest {
    func testConfigAndReceiptFilesArePrivateAndInvalidConfigThrows() throws {
        let files = SafetyFiles(directory: folder.appendingPathComponent("state"))
        let config = SafetyConfig(enabled: true)
        try files.save(config, to: files.configURL)
        XCTAssertEqual(try files.loadConfig(), config)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files.configURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try Data("invalid".utf8).write(to: files.configURL)
        XCTAssertThrowsError(try files.loadConfig())
    }
    func service(command: @escaping (String, [String]) throws -> (Int32, String), legacy: Bool = false) throws -> GuardService {
        let helper = folder.appendingPathComponent("ClaudeGuard")
        try Data("fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let legacyURL = folder.appendingPathComponent("legacy.plist")
        if legacy { try Data().write(to: legacyURL) }
        return GuardService(files: SafetyFiles(directory: folder.appendingPathComponent("state")), helper: helper,
                            launchAgents: folder.appendingPathComponent("LaunchAgents"), legacyPlist: legacyURL, command: command)
    }
    func testEnableRegistersOnlyUserAgentAndUsesBundleHelper() throws {
        var calls: [[String]] = []
        let service = try service { _, args in calls.append(args); return (args.first == "print" ? 1 : 0, "") }
        try service.enable(SafetyConfig(enabled: true))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: service.plistURL), format: nil) as! [String: Any]
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [service.helper.path, "--config", service.files.configURL.path])
        XCTAssertEqual(plist["StartInterval"] as? Int, 10)
        XCTAssertTrue(calls.contains { $0.first == "bootstrap" && $0[1].hasPrefix("gui/") })
        XCTAssertFalse(calls.flatMap { $0 }.contains("system"))
    }
    func testBootstrapFailureIsReportedAndCannotLookRegistered() throws {
        let service = try service { _, _ in (1, "") }
        XCTAssertThrowsError(try service.enable(SafetyConfig(enabled: true)))
        XCTAssertFalse(service.registered)
        XCTAssertNil(service.files.loadReceipt())
    }
    func testLegacyGuardPreventsParallelInstallation() throws {
        var called = false
        let service = try service(command: { _, _ in called = true; return (0, "") }, legacy: true)
        XCTAssertThrowsError(try service.enable(SafetyConfig(enabled: true)))
        XCTAssertFalse(called); XCTAssertFalse(FileManager.default.fileExists(atPath: service.files.configURL.path))
    }
    func testStopDisablesAndRemovesOnlyOwnAgentNotProfiles() throws {
        var registered = true
        let service = try service { _, args in
            if args.first == "print" { return (registered ? 0 : 1, "") }
            if args.first == "bootout" { registered = false }
            return (0, "")
        }
        try service.files.save(SafetyConfig(enabled: true), to: service.files.configURL)
        try Data("fixture".utf8).write(to: directory("LaunchAgents").appendingPathComponent(GuardService.label + ".plist"))
        let preserved = try directory("Claude-Profiles").appendingPathComponent("keep")
        try Data("login".utf8).write(to: preserved)
        try service.disable()
        XCTAssertFalse(try service.files.loadConfig().enabled); XCTAssertFalse(registered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.plistURL.path))
        XCTAssertEqual(try String(contentsOf: preserved), "login")
    }
}

final class ProfileTests: FixtureTest {
    func paths() throws -> (URL, URL, URL) {
        let live = try directory("Claude"), park = try directory("Claude-Profiles"), marker = folder.appendingPathComponent("current")
        try Data("source".utf8).write(to: live.appendingPathComponent("login"))
        try directory("Claude-Profiles/Business").appendingPathComponent("login").writeFixture("target")
        try Data("Personal".utf8).write(to: marker)
        return (live, park, marker)
    }
    func testSuccessfulSwitchKeepsBothIdentities() throws {
        let (live, park, marker) = try paths()
        try ProfileTransaction(live: live, parked: park, marker: marker).switchProfile(from: "Personal", to: "Business")
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("login")), "target")
        XCTAssertEqual(try String(contentsOf: park.appendingPathComponent("Personal/login")), "source")
        XCTAssertEqual(try String(contentsOf: marker), "Business")
    }
    func testExistingArchiveIsNeverOverwritten() throws {
        let (live, park, marker) = try paths()
        try directory("Claude-Profiles/Personal").appendingPathComponent("keep").writeFixture("unique")
        XCTAssertThrowsError(try ProfileTransaction(live: live, parked: park, marker: marker).switchProfile(from: "Personal", to: "Business"))
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("login")), "source")
        XCTAssertEqual(try String(contentsOf: park.appendingPathComponent("Personal/keep")), "unique")
    }
    func testFailedSecondMoveRestoresSourceAndMarker() throws {
        let (live, park, marker) = try paths()
        var calls = 0
        let operation = ProfileTransaction(live: live, parked: park, marker: marker, move: { a, b in
            calls += 1
            if calls == 2 { throw SafetyError("disk failure") }
            try FileManager.default.moveItem(at: a, to: b)
        })
        XCTAssertThrowsError(try operation.switchProfile(from: "Personal", to: "Business"))
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("login")), "source")
        XCTAssertEqual(try String(contentsOf: park.appendingPathComponent("Business/login")), "target")
        XCTAssertEqual(try String(contentsOf: marker), "Personal")
    }
    func testMarkerFailureRestoresBothFolders() throws {
        let (live, park, marker) = try paths()
        let operation = ProfileTransaction(live: live, parked: park, marker: marker, writeMarker: { _, _ in throw SafetyError("write failure") })
        XCTAssertThrowsError(try operation.switchProfile(from: "Personal", to: "Business"))
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("login")), "source")
        XCTAssertEqual(try String(contentsOf: park.appendingPathComponent("Business/login")), "target")
    }
    func testMissingTargetCreatesSignedOutDirectoryWithoutDiscardingSource() throws {
        let (live, park, marker) = try paths()
        try ProfileTransaction(live: live, parked: park, marker: marker).switchProfile(from: "Personal", to: "New")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: live.path).isEmpty)
        XCTAssertEqual(try String(contentsOf: park.appendingPathComponent("Personal/login")), "source")
    }
    func testInvalidNamesAndSymlinkTargetsAreRejectedBeforeMoves() throws {
        let (live, park, marker) = try paths()
        let transaction = ProfileTransaction(live: live, parked: park, marker: marker)
        for target in ["../Other", ".hidden", "", " personal ", "personal", "Work\nOther"] {
            XCTAssertThrowsError(try transaction.switchProfile(from: "Personal", to: target))
        }
        try FileManager.default.createSymbolicLink(at: park.appendingPathComponent("Link"), withDestinationURL: folder)
        XCTAssertThrowsError(try transaction.switchProfile(from: "Personal", to: "Link"))
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("login")), "source")
    }
    func testNonDirectoryTargetIsRejectedBeforeMovingSource() throws {
        let (live, park, marker) = try paths()
        try Data("unexpected file".utf8).write(to: park.appendingPathComponent("Broken"))
        XCTAssertThrowsError(try ProfileTransaction(live: live, parked: park, marker: marker)
            .switchProfile(from: "Personal", to: "Broken"))
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("login")), "source")
    }
}

private extension URL {
    func writeFixture(_ text: String) throws { try Data(text.utf8).write(to: self) }
}
