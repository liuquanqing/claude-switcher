import XCTest
@testable import SwitcherCore

final class AppUpdateInstallTests: FixtureTest {
    @MainActor func scenario(exit: Bool = true, acknowledge: Bool = true, failValidation: Bool = false,
                             failExchange: Bool = false, refuseQuit: Bool = false, resume: Bool = false, failLaunch: Bool = false) async throws -> (AppUpdateInstallResult, String, Int) {
        let root = try directory(UUID().uuidString), id = UUID()
        let app = root.appendingPathComponent("Fixture.app"), staged = root.appendingPathComponent(".claude-switcher-update-\(id.uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data((resume ? "new" : "old").utf8).write(to: app.appendingPathComponent("version"))
        try Data((resume ? "old" : "new").utf8).write(to: staged.appendingPathComponent("version"))
        let plan = AppUpdateInstallPlan(id: id, application: app, stagedApplication: staged, oldBuild: "1", newBuild: "2", release: "2.0.0")
        var now = Date(), running = !resume, ack = false, swaps = 0
        let result = await AppUpdateInstall.run(plan: plan, operations: .init(validate: {
            try plan.validatePaths()
            if failValidation { throw SafetyError("fixture invalid signature") }
        }, isRunning: { running }, exchange: {
            if failExchange { throw SafetyError("fixture disk failure") }
            try AppUpdateInstallPlan.exchange(app, staged); swaps += 1
        }, launch: {
            let version = try String(contentsOf: app.appendingPathComponent("version"))
            if failLaunch && version == "new" { throw SafetyError("fixture launch failed") }
            running = true
            ack = acknowledge && version == "new"
        }, acknowledged: { ack }, quitNewApplication: {
            if !refuseQuit { running = false }
        }, record: { _ in }, now: { now }, wait: {
            now = now.addingTimeInterval(1)
            if exit && swaps == 0 && !resume { running = false }
        }), exitTimeout: 2, launchTimeout: 2, resumeAfterSwap: resume)
        return (result, try String(contentsOf: app.appendingPathComponent("version")), swaps)
    }
    @MainActor func testAtomicReplacementAndVerifiedRestart() async throws {
        let (result, version, swaps) = try await scenario()
        XCTAssertEqual(result.state, .complete); XCTAssertEqual(version, "new"); XCTAssertEqual(swaps, 1)
    }
    @MainActor func testBadPayloadAndQuitRefusalNeverReplaceOldApp() async throws {
        for options in [(false, true, false), (true, false, false), (false, false, true)] {
            let (result, version, swaps) = try await scenario(exit: !options.0, failValidation: options.1, failExchange: options.2)
            XCTAssertEqual(result.state, .failed); XCTAssertEqual(version, "old"); XCTAssertEqual(swaps, 0)
        }
    }
    @MainActor func testMissingStartupAcknowledgementRollsBack() async throws {
        let (result, version, swaps) = try await scenario(acknowledge: false)
        XCTAssertEqual(result.state, .rolledBack); XCTAssertEqual(version, "old"); XCTAssertEqual(swaps, 2)
    }
    @MainActor func testRefusingNewAppIsNotForceKilledOrOverwritten() async throws {
        let (result, version, swaps) = try await scenario(acknowledge: false, refuseQuit: true)
        XCTAssertEqual(result.state, .recoveryRequired); XCTAssertEqual(version, "new"); XCTAssertEqual(swaps, 1)
    }
    @MainActor func testInterruptedSwapCanResumeWithoutExchangingTwice() async throws {
        let (result, version, swaps) = try await scenario(resume: true)
        XCTAssertEqual(result.state, .complete); XCTAssertEqual(version, "new"); XCTAssertEqual(swaps, 0)
    }
    @MainActor func testLaunchFailureRestoresOldBundle() async throws {
        let (result, version, swaps) = try await scenario(failLaunch: true)
        XCTAssertEqual(result.state, .rolledBack)
        XCTAssertEqual(version, "old"); XCTAssertEqual(swaps, 2)
    }
    func testDowngradeAndUnownedStageAreRejected() throws {
        let root = try directory("invalid-update"), id = UUID()
        let app = root.appendingPathComponent("Fixture.app")
        let stage = root.appendingPathComponent(".claude-switcher-update-\(id.uuidString).app")
        for path in [app, stage] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        for build in ["1", "0", "2..1", "unknown"] {
            XCTAssertThrowsError(try AppUpdateInstallPlan(id:id, application:app, stagedApplication:stage,
                oldBuild:"1", newBuild:build, release:"fixture").validatePaths())
        }
        XCTAssertThrowsError(try AppUpdateInstallPlan(id:UUID(), application:app, stagedApplication:stage,
            oldBuild:"1", newBuild:"2", release:"fixture").validatePaths())
    }
    func testSymlinkDestinationIsRejectedWithoutChangingTarget() throws {
        let root = try directory("symlink-update"), id = UUID()
        let real = root.appendingPathComponent("Unrelated.app"), app = root.appendingPathComponent("Fixture.app")
        let stage = root.appendingPathComponent(".claude-switcher-update-\(id.uuidString).app")
        for path in [real, stage] { try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true) }
        try Data("unchanged".utf8).write(to:real.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at:app,withDestinationURL:real)
        XCTAssertThrowsError(try AppUpdateInstallPlan(id:id,application:app,stagedApplication:stage,
            oldBuild:"1",newBuild:"2",release:"fixture").validatePaths())
        XCTAssertEqual(try String(contentsOf:real.appendingPathComponent("sentinel")), "unchanged")
    }
    @MainActor func testSeparateFictionalProcessesAcknowledgeTheReplacedVersion() async throws {
        let root = try directory("process-update"), id = UUID()
        let app = root.appendingPathComponent("Fixture.app"), staged = root.appendingPathComponent(".claude-switcher-update-\(id.uuidString).app")
        let acknowledgement = root.appendingPathComponent("ack")
        for (path, version) in [(app, "old"), (staged, "new")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: path.appendingPathComponent("version"))
            let entry = path.appendingPathComponent("fixture")
            try "#!/bin/sh\n/bin/cat \"\u{24}{0%/*}/version\" > \"$1\"\nexec /bin/sleep 10\n".write(to: entry, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry.path)
        }
        var process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["10"]
        try process.run()
        let old = process
        defer { if process.isRunning { process.terminate() }; if old.isRunning { old.terminate() } }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if old.isRunning { old.terminate() }
        }
        let plan = AppUpdateInstallPlan(id: id, application: app, stagedApplication: staged, oldBuild: "1", newBuild: "2", release: "2.0.0")
        let result = await AppUpdateInstall.run(plan: plan, operations: .init(validate: { try plan.validatePaths() },
            isRunning: { process.isRunning }, exchange: { try AppUpdateInstallPlan.exchange(app, staged) }, launch: {
                process = Process(); process.executableURL = app.appendingPathComponent("fixture")
                process.arguments = [acknowledgement.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run()
            }, acknowledged: { process.isRunning && (try? String(contentsOf: acknowledgement)) == "new" },
            quitNewApplication: { if process.isRunning { process.terminate() }; process.waitUntilExit() }, record: { _ in },
            wait: { try await Task.sleep(nanoseconds: 50_000_000) }), exitTimeout: 3, launchTimeout: 3)
        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("version")), "old")
    }
}
