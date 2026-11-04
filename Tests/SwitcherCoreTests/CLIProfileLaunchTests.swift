import Foundation
import XCTest
@testable import SwitcherCore

final class CLIProfileLaunchTests: FixtureTest {
    func testCommandSelectsASeparateDirectoryWithoutWritingAnything() throws {
        let home = try directory("fictional-home")
        let profile = "Team's $notes"
        let command = try CLIProfileLaunch.command(profile: profile, home: home)
        let shell = Process(), stdout = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "claude() { printf '%s' \"$CLAUDE_CONFIG_DIR\"; }; " + command]
        shell.standardOutput = stdout
        try shell.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), home.appendingPathComponent(".claude-switcher-cli/" + profile).path)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    func testInvalidNameAndSymbolicLinksAreRejected() throws {
        let home = try directory("fictional-home")
        XCTAssertThrowsError(try CLIProfileLaunch.command(profile: "../default", home: home))
        let root = try directory("fictional-home/.claude-switcher-cli")
        let original = try directory("fictional-home/.claude")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Team"), withDestinationURL: original)
        XCTAssertThrowsError(try CLIProfileLaunch.command(profile: "Team", home: home))
    }
}
