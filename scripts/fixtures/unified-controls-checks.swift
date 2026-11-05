import Foundation
import SwitcherCore

@MainActor func unifiedControlsChecks() async throws -> Int {
    var checks = 0
    func require(_ value: Bool, _ text: String) { precondition(value, text); checks += 1 }
    let identity = CLIIdentity(accountID: "fixture-a", organizationID: "fixture-org", email: "a@example.invalid")
    let other = CLIIdentity(accountID: "fixture-b", organizationID: "fixture-org", email: "b@example.invalid")
    var context: CLIConnectionContext? = .init(profile: "Personal", identity: identity)
    var bindings: [String: CLIBinding] = [:], launched: [CLIBinding] = []
    var defaultStatus: CLIBindingStatus = .matched, isolatedStatus: CLIBindingStatus = .notLoggedIn
    var failure = false
    let fakeHome = URL(fileURLWithPath: "/fixture-home")
    let operations = CLIConnectionOperations(context: { context }, load: { bindings[try CLIBinding.key($0)] }, save: {
        bindings[try CLIBinding.key($0.identity)] = $0
    }, make: { mode, id in
        CLIBinding(identity: id, choice: mode, directory: try CLIBinding.directory(for: mode, identity: id, home: fakeHome))
    }, status: { binding in
        if failure { throw SafetyError("fixture timeout") }
        return binding.choice == .defaultLogin ? defaultStatus : isolatedStatus
    }, launch: { launched.append($0) })
    let controller = CLIConnectionController(operations: operations)
    await controller.open()
    require(controller.phase == .matched && controller.choice == .defaultLogin && launched.count == 1,
            "matching existing default login is reused without creating another directory")
    let first = launched[0]
    await controller.open()
    require(launched.count == 2 && launched[1] == first && bindings.count == 1,
            "returning to an account reuses its binding and original history location")
    defaultStatus = .different; controller.defaultLoginDidChange()
    require(controller.phase == .unconfirmed, "external default login change invalidates a prior match")
    await controller.open()
    require(controller.phase == .mismatched && launched.count == 2, "a different default account is not overwritten or opened as a match")
    await controller.choose(.isolated)
    require(controller.phase == .waitingForLogin && launched.last?.choice == .isolated,
            "opening an isolated directory does not mean official login has completed")
    isolatedStatus = .matched; await controller.confirmLogin()
    require(controller.phase == .matched && controller.checkedAt != nil, "the official identity report completes linking")
    context = .init(profile: "Business", identity: other); defaultStatus = .different
    await controller.open()
    require(controller.phase == .choosing && controller.expectedProfile == "Business", "a second account gets a setup step, not the first account's directory")
    let before = launched.count; failure = true
    await controller.choose(.isolated)
    require(controller.phase == .failed && launched.count == before && bindings.count == 1,
            "status timeout is an error, not an instruction to relogin or create a successful binding")

    var finish: CheckedContinuation<CLIBindingStatus, Never>?
    let delayed = CLIConnectionController(operations: .init(context: { context }, load: { _ in nil }, save: { _ in preconditionFailure("stale result must not save") }, make: operations.make,
        status: { _ in await withCheckedContinuation { finish = $0 } }, launch: { _ in preconditionFailure("stale result must not launch") }))
    let request = Task { @MainActor in await delayed.open() }
    while finish == nil { await Task.yield() }
    context = .init(profile: "Personal", identity: identity); delayed.contextDidChange()
    finish!.resume(returning: .matched); await request.value
    require(delayed.phase == .unlinked && delayed.expectedProfile == "Personal", "a late report cannot link the account selected afterwards")

    var reusedDirectory: CLIBinding?
    let existingIsolated = CLIConnectionController(operations: .init(context: { context }, load: { _ in nil }, save: { reusedDirectory = $0 }, make: operations.make,
        status: { $0.choice == .isolated ? .matched : .different }, launch: { _ in }, existingDirectory: { $0.choice == .isolated }))
    await existingIsolated.open()
    require(existingIsolated.phase == .matched && reusedDirectory?.choice == .isolated,
            "an already logged-in owned directory is reused without asking for another login")

    let env = CLITerminalLaunch.environment(home: fakeHome, directory: fakeHome.appendingPathComponent(".claude"), inherited: ["CLAUDE_CONFIG_DIR": "/other", "ANTHROPIC_API_KEY": "fictional", "CLAUDE_ENV_FILE": "/fixture/previous-session-env", "HTTPS_PROXY": "http://fixture.invalid:1234"])
    require(env["CLAUDE_CONFIG_DIR"] == nil && env["ANTHROPIC_API_KEY"] == nil && env["CLAUDE_ENV_FILE"] == nil && env["HTTPS_PROXY"] != nil,
            "the explicit subscription launcher selects the probed directory and retains proxy routing")
    let command = try CLITerminalLaunch.script(binding: first, executable: URL(fileURLWithPath: "/fixture/bin/claude"), home: fakeHome)
    require(!command.contains("/login") && !command.contains("/logout") && command.contains("exec /usr/bin/env") && command.contains("-u CLAUDE_ENV_FILE"),
            "launching never forces a login overwrite or logout")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-launch-fixture-" + UUID().uuidString)
    let quotedHome = root.appendingPathComponent("home with ' quote")
    try FileManager.default.createDirectory(at: quotedHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fakeCLI = quotedHome.appendingPathComponent("fictional-cli")
    try "#!/bin/sh\n[ -z \"$ANTHROPIC_API_KEY$CLAUDE_ENV_FILE$CLAUDE_CONFIG_DIR\" ] || exit 7\n[ \"$HTTPS_PROXY\" = 'http://fixture.invalid:1234' ] || exit 8\nprintf fixture-ok\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
    let quotedBinding = CLIBinding(identity: identity, choice: .defaultLogin, directory: quotedHome.appendingPathComponent(".claude"))
    let launcher = root.appendingPathComponent("launch.command")
    try CLITerminalLaunch.script(binding: quotedBinding, executable: fakeCLI, home: quotedHome).write(to: launcher, atomically: true, encoding: .utf8)
    let launchedFixture = try await BoundedCLICommand.run(home: quotedHome, executable: URL(fileURLWithPath: "/bin/zsh"),
        arguments: [launcher.path], inherited: ["HOME": quotedHome.path, "ANTHROPIC_API_KEY": "fictional", "CLAUDE_ENV_FILE": "/fictional", "CLAUDE_CONFIG_DIR": "/fictional", "HTTPS_PROXY": "http://fixture.invalid:1234"], timeoutSeconds: 5, graceSeconds: 1)
    require(launchedFixture.status == 0 && launchedFixture.text == "fixture-ok",
            "generated launcher handles quoted paths and clears inherited authentication while retaining proxy routing")
    let updatingStore = Store(demo: true)
    updatingStore.currentCLIRecoveryRunning = true
    require(ApplicationInstall.hasActiveWork(updatingStore), "installation waits for an in-flight login operation")
    updatingStore.currentCLIRecoveryRunning = false; updatingStore.automaticRefreshInProgress = true
    require(ApplicationInstall.hasActiveWork(updatingStore), "installation waits for the existing automatic refresh to settle")
    updatingStore.automaticRefreshInProgress = false; updatingStore.updating = true
    let originalStatus = updatingStore.cliStatus
    await updatingStore.verifyDefaultCLI()
    require(updatingStore.busy == nil && updatingStore.cliStatus == originalStatus,
            "manual verification cannot start another login check during installation")
    return checks
}
