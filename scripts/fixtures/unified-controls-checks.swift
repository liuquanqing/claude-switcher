import Foundation
import SwitcherCore

private extension CLIConnectionOperations {
    @MainActor init(context: @escaping () -> CLIConnectionContext?, load: @escaping (CLIIdentity) throws -> CLIBinding?,
                    save: @escaping (CLIBinding) throws -> Void, make: @escaping (CLIBindingChoice, CLIIdentity) throws -> CLIBinding,
                    status: @escaping (CLIBinding) async throws -> CLIBindingStatus, launch: @escaping (CLIBinding) async throws -> Void,
                    existingDirectory: @escaping (CLIBinding) -> Bool = { _ in false },
                    localRecord: @escaping (CLIIdentity, CLIBinding?) -> CLILocalRecord = { _, _ in .unconfirmed },
                    hasRecoverableBackup: @escaping (CLIConnectionContext) throws -> Bool = { _ in false },
                    restoreLegacyBackup: @escaping (CLIConnectionContext) async throws -> Void = { _ in throw SafetyError("fixture backup unavailable") }) {
        self.init(context: context, load: load, save: save, make: make,
                  access: { CLIConnectionAccess(status: status, launch: { binding, _ in try await launch(binding) }) },
                  existingDirectory: existingDirectory, localRecord: localRecord,
                  hasRecoverableBackup: hasRecoverableBackup, restoreLegacyBackup: restoreLegacyBackup)
    }
}

@MainActor func unifiedControlsChecks() async throws -> Int {
    var checks = 0
    func require(_ value: Bool, _ text: String) { precondition(value, text); checks += 1 }
    let identity = CLIIdentity(accountID: "fixture-a", organizationID: "fixture-org", email: "a@example.invalid")
    let other = CLIIdentity(accountID: "fixture-b", organizationID: "fixture-org", email: "b@example.invalid")
    var context: CLIConnectionContext? = .init(profile: "Personal", identity: identity)
    var bindings: [String: CLIBinding] = [:], launched: [CLIBinding] = []
    var defaultStatus: CLIBindingStatus = .matched, isolatedStatus: CLIBindingStatus = .notLoggedIn
    var failure = false, statusReads = 0
    let fakeHome = URL(fileURLWithPath: "/fixture-home")
    let operations = CLIConnectionOperations(context: { context }, load: { bindings[try CLIBinding.key($0)] }, save: {
        bindings[try CLIBinding.key($0.identity)] = $0
    }, make: { mode, id in
        CLIBinding(identity: id, choice: mode, directory: try CLIBinding.directory(for: mode, identity: id, home: fakeHome))
    }, status: { binding in
        statusReads += 1
        if failure { throw SafetyError("fixture timeout") }
        return binding.choice == .defaultLogin ? defaultStatus : isolatedStatus
    }, launch: { launched.append($0) })
    var withRecords = operations
    var observedRecord: CLILocalRecord = .sameAccount(.defaultLogin)
    withRecords.localRecord = { identity, binding in
        if identity.samePrincipal(as: other) { return .notPrepared }
        if binding?.choice == .isolated, observedRecord == .differentAccount { return .notPrepared }
        return observedRecord
    }
    let controller = CLIConnectionController(operations: withRecords)
    controller.contextDidChange()
    require(controller.localRecord == .sameAccount(.defaultLogin) && controller.phase == .unlinked
                && bindings.isEmpty && launched.isEmpty && statusReads == 0,
            "a local record is shown without being saved as a verified binding")
    await controller.open()
    require(controller.phase == .matched && controller.choice == .defaultLogin && launched.count == 1,
            "matching existing default login is reused without creating another directory")
    let first = launched[0]
    await controller.open()
    require(launched.count == 2 && launched[1] == first && bindings.count == 1,
            "returning to an account reuses its binding and original history location")
    observedRecord = .differentAccount
    controller.refreshLocalRecord()
    require(controller.localRecord == .differentAccount && controller.phase == .unconfirmed && controller.checkedAt == nil,
            "a changed local account record invalidates the previous identity match without opening a CLI")
    defaultStatus = .different; controller.defaultLoginDidChange()
    require(controller.phase == .unconfirmed, "external default login change invalidates a prior match")
    await controller.open()
    require(controller.phase == .mismatched && launched.count == 2 && !controller.defaultLoginAvailable,
            "a different signed-in account is not offered as a default login option")
    await controller.choose(.isolated)
    require(controller.phase == .waitingForLogin && launched.last?.choice == .isolated,
            "opening an isolated directory does not mean official login has completed")
    isolatedStatus = .matched; await controller.confirmLogin()
    require(controller.phase == .matched && controller.checkedAt != nil, "the official identity report completes linking")
    var backedUp: [CLIConnectionContext] = []
    var backupDenied = false
    var backupOperations = operations
    backupOperations.backupDefaultLogin = {
        if backupDenied { throw SafetyError("fixture backup denied") }
        backedUp.append($0)
    }
    let loginBackup = CLIConnectionController(operations: backupOperations)
    defaultStatus = .matched
    await loginBackup.choose(.defaultLogin)
    require(backedUp == [context!] && loginBackup.phase == .matched, "opening the matching default login completes its backup")
    backupDenied = true
    await loginBackup.confirmLogin()
    require(loginBackup.phase == .matched && loginBackup.detail?.contains("备份尚未更新") == true,
            "backup failure preserves successful login while exposing that backup is pending")
    backupDenied = false
    await loginBackup.confirmLogin()
    require(backedUp.count == 2 && loginBackup.detail == nil, "confirming a login retries a pending default backup")
    let countBeforeSeparate = backedUp.count
    await loginBackup.choose(.isolated)
    require(backedUp.count == countBeforeSeparate, "an isolated login is never copied into the default-account backup")
    context = .init(profile: "Business", identity: other); defaultStatus = .different
    controller.contextDidChange()
    require(controller.localRecord == .notPrepared, "switching the desktop account immediately updates the CLI record")
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

    observedRecord = .sameAccount(.isolated)
    let launchesBeforeReturn = launched.count
    controller.contextDidChange()
    require(controller.expectedProfile == "Personal" && controller.choice == .isolated
                && controller.localRecord == .sameAccount(.isolated) && launched.count == launchesBeforeReturn,
            "returning to account A restores A's saved terminal directory without starting a terminal")

    var reusedDirectory: CLIBinding?
    let existingIsolated = CLIConnectionController(operations: .init(context: { context }, load: { _ in nil }, save: { reusedDirectory = $0 }, make: operations.make,
        status: { $0.choice == .isolated ? .matched : .different }, launch: { _ in }, existingDirectory: { $0.choice == .isolated }))
    await existingIsolated.open()
    require(existingIsolated.phase == .matched && reusedDirectory?.choice == .isolated,
            "an already logged-in owned directory is reused without asking for another login")

    var reopenedDefault: CLIBinding?
    let expiredDefault = CLIConnectionController(operations: .init(context: { context }, load: { _ in nil },
        save: { _ in }, make: operations.make, status: { _ in .notLoggedIn },
        launch: { reopenedDefault = $0 }, localRecord: { _, _ in .sameAccount(.defaultLogin) }))
    await expiredDefault.open()
    require(expiredDefault.phase == .waitingForLogin && reopenedDefault?.choice == .defaultLogin,
            "an explicit sign-in action reopens the matching default directory without creating a new profile")

    var backupChecks: [String] = [], restored: [CLIConnectionContext] = [], openedForRecovery: [CLIBinding] = []
    var backupExists = true, backupReadable = true, backupMatches = true
    var reportedDefault: CLIBindingStatus = .notLoggedIn
    var reportedIsolated: CLIBindingStatus = .notLoggedIn
    var recoveryBinding: CLIBinding?
    let recovery = CLIConnectionController(operations: .init(context: { context }, load: { _ in recoveryBinding },
        save: { recoveryBinding = $0 }, make: operations.make,
        status: { $0.choice == .defaultLogin ? reportedDefault : reportedIsolated },
        launch: { openedForRecovery.append($0) }, existingDirectory: { $0.choice == .isolated },
        localRecord: { _, _ in .sameAccount(.defaultLogin) }, hasRecoverableBackup: { expected in
            backupChecks.append(expected.profile)
            if !backupReadable { throw SafetyError("fictional access failure") }
            return backupExists
        }, restoreLegacyBackup: {
            guard backupMatches else { throw SafetyError("fixture backup mismatch") }
            restored.append($0)
        }))
    let personal = context!
    await recovery.open(showLoginChoices: true)
    require(recovery.phase == .choosing && recovery.legacyBackupAvailable && recovery.defaultLoginAvailable &&
            openedForRecovery.isEmpty && restored.isEmpty && recoveryBinding == nil,
            "signed-out default remains a sign-in option even when an old backup exists")
    await recovery.restoreLegacyBackup(for: .init(profile: personal.profile, identity: other))
    require(restored.isEmpty && recovery.legacyBackupAvailable, "confirmation for a different identity cannot restore")
    backupMatches = false
    await recovery.restoreLegacyBackup(for: personal)
    require(recovery.phase == .choosing && recovery.detail == "fixture backup mismatch" && recovery.defaultLoginAvailable &&
            restored.isEmpty && openedForRecovery.isEmpty && recoveryBinding == nil,
            "a rejected backup returns to setup and leaves default sign-in available without changing any login")
    backupMatches = true
    await recovery.restoreLegacyBackup(for: personal)
    require(restored == [personal] && !recovery.legacyBackupAvailable && openedForRecovery.isEmpty,
            "only a matching explicit confirmation restores; it does not launch a terminal")

    reportedIsolated = .matched
    await recovery.open()
    require(recovery.phase == .matched && recovery.choice == .isolated && backupChecks.count == 1,
            "an existing verified isolated login wins over a signed-out default and old backup")
    reportedDefault = .matched
    await recovery.open()
    require(recovery.phase == .matched && recovery.choice == .isolated && backupChecks.count == 1,
            "the saved isolated choice wins when both directories match")
    await recovery.open(showLoginChoices: true)
    require(recovery.phase == .choosing && recovery.defaultMatches && recovery.choice == .isolated,
            "manual terminal options offer a matching default without changing the saved choice")
    await recovery.choose(.defaultLogin)
    require(recovery.phase == .matched && recovery.choice == .defaultLogin,
            "an explicit selection changes the preferred directory")
    reportedIsolated = .notLoggedIn
    reportedDefault = .notLoggedIn
    backupReadable = false
    await recovery.open(showLoginChoices: true)
    require(recovery.phase == .choosing && !recovery.legacyBackupAvailable && recovery.detail != nil && openedForRecovery.count == 3,
            "unknown backup status does not silently start a fresh login")
    backupReadable = true
    await recovery.open()
    context = .init(profile: "Business", identity: other)
    await recovery.restoreLegacyBackup(for: personal)
    require(restored == [personal] && !recovery.legacyBackupAvailable,
            "an account switch invalidates a pending restore confirmation")
    context = personal; recoveryBinding = nil; backupExists = false
    await recovery.open()
    require(recovery.phase == .waitingForLogin && openedForRecovery.last?.choice == .defaultLogin && restored == [personal],
            "when neither usable login nor backup exists, an explicit open uses official login")
    backupExists = true
    let launchedBeforeOptions = openedForRecovery
    await recovery.open(showLoginChoices: true)
    require(recovery.phase == .choosing && recovery.legacyBackupAvailable && recovery.defaultLoginAvailable
            && openedForRecovery == launchedBeforeOptions && restored == [personal],
            "sign-in options return a waiting login to backup selection without launching or restoring")

    var uncertainLaunches: [CLIBinding] = [], uncertainSaves: [CLIBinding] = []
    let uncertainDefault = CLIConnectionController(operations: .init(context: { context }, load: { _ in nil },
        save: { uncertainSaves.append($0) }, make: operations.make,
        status: { $0.choice == .defaultLogin ? .unconfirmed : .notLoggedIn },
        launch: { uncertainLaunches.append($0) }))
    await uncertainDefault.open()
    require(uncertainDefault.phase == .choosing && uncertainSaves.isEmpty && uncertainLaunches.isEmpty,
            "an unconfirmed default may offer separate setup without declaring logout or changing the default")
    await uncertainDefault.choose(.defaultLogin)
    require(uncertainDefault.phase == .unconfirmed && uncertainSaves.isEmpty && uncertainLaunches.isEmpty,
            "an unconfirmed default is never saved or opened as the desktop account")
    await uncertainDefault.choose(.isolated)
    require(uncertainDefault.phase == .waitingForLogin && uncertainSaves.last?.choice == .isolated
                && uncertainLaunches.last?.choice == .isolated,
            "separate official login remains available when the default cannot be reused")

    var freshLaunch: CLIBinding?
    var defaultRecord: CLILocalRecord = .notPrepared
    let signedOut = CLIConnectionController(operations: .init(context: { context }, load: { _ in nil },
        save: { _ in }, make: operations.make, status: { _ in .notLoggedIn }, launch: { freshLaunch = $0 },
        localRecord: { _, _ in defaultRecord }))
    await signedOut.open()
    require(signedOut.phase == .waitingForLogin && freshLaunch?.choice == .defaultLogin,
            "an empty default directory is preferred for a new sign-in")
    freshLaunch = nil; defaultRecord = .differentAccount
    await signedOut.open()
    require(signedOut.phase == .mismatched && freshLaunch == nil,
            "a signed-out default with another account's local record is not automatically reused")

    let arbitraryProfile = CLIConnectionContext(profile: "Research Team", identity: other)
    let separateBinding = try operations.make(.isolated, other)
    var heldBinding: CLIBinding? = separateBinding
    var preparations = 0
    var inspections: [CLIBindingChoice] = []
    var terminalIntents: [CLITerminalIntent] = []
    var routeBlocked = false
    var routeStatus: CLIBindingStatus = .notLoggedIn
    let multiAccountOperations = CLIConnectionOperations(context: { arbitraryProfile }, load: { _ in heldBinding },
        save: { heldBinding = $0 }, make: operations.make, access: {
            preparations += 1
            if routeBlocked { throw CLITerminalFailure.route(SafetyDecision(.countryUnknown)) }
            return CLIConnectionAccess(status: { candidate in
                inspections.append(candidate.choice)
                return candidate.choice == .isolated ? routeStatus : .different
            }, launch: { candidate, intent in
                require(candidate == separateBinding, "only the selected account directory can be opened")
                terminalIntents.append(intent)
            })
        }, backupDefaultLogin: { _ in preconditionFailure("separate terminal must not write the default backup") },
        localRecord: { _, candidate in candidate?.choice == .isolated ? .notPrepared : .differentAccount },
        restoreLegacyBackup: { _ in preconditionFailure("opening and changing directories never restore a backup") })
    let multiAccount = CLIConnectionController(operations: multiAccountOperations)
    await multiAccount.open()
    require(multiAccount.expectedProfile == arbitraryProfile.profile && multiAccount.preferredChoice == .isolated
            && multiAccount.phase == .waitingForLogin && preparations == 1 && inspections == [.isolated]
            && terminalIntents == [.signIn],
            "a remembered separate account uses one gate, no default login check, and official sign-in when signed out")
    await multiAccount.confirmLogin()
    require(multiAccount.phase == .waitingForLogin && terminalIntents == [.signIn],
            "a local signed-out report cannot confirm the browser flow or launch a second process")
    routeStatus = .matched
    await multiAccount.confirmLogin()
    await multiAccount.open()
    require(multiAccount.phase == .matched && terminalIntents == [.signIn, .open],
            "a completed match opens a session without restarting sign-in")
    routeBlocked = true
    await multiAccount.open()
    require(multiAccount.phase == .failed && multiAccount.routeDecision?.reason == .countryUnknown
            && terminalIntents == [.signIn, .open] && inspections.allSatisfy { $0 == .isolated },
            "an indeterminate route fails closed before touching either login or opening a terminal")
    routeBlocked = false
    await multiAccount.open(showLoginChoices: true)
    require(multiAccount.phase == .choosing && !multiAccount.defaultLoginAvailable && heldBinding == separateBinding,
            "manual options keep another account's default login unavailable")
    await multiAccount.choose(.defaultLogin)
    require(multiAccount.phase == .mismatched && heldBinding == separateBinding && terminalIntents == [.signIn, .open],
            "manual choice rechecks identity and refuses another account's default directory")
    heldBinding = nil
    inspections.removeAll()
    routeStatus = .notLoggedIn
    let newAccount = CLIConnectionController(operations: multiAccountOperations)
    await newAccount.open()
    require(newAccount.phase == .waitingForLogin && inspections == [.isolated] && heldBinding == separateBinding,
            "a new account with a different default owner starts in its own directory")
    require(AppLocalization.text("cli.openNamedIsolated", language: "zh", arguments: ["account": arbitraryProfile.profile])
            .contains(arbitraryProfile.profile), "terminal action labels use the current account name")
    let env = CLITerminalLaunch.environment(home: fakeHome, directory: fakeHome.appendingPathComponent(".claude"), inherited: ["CLAUDE_CONFIG_DIR": "/other", "ANTHROPIC_API_KEY": "fictional", "CLAUDE_ENV_FILE": "/fixture/previous-session-env", "HTTPS_PROXY": "http://fixture.invalid:1234"])
    require(env["CLAUDE_CONFIG_DIR"] == nil && env["ANTHROPIC_API_KEY"] == nil && env["CLAUDE_ENV_FILE"] == nil && env["HTTPS_PROXY"] != nil,
            "the explicit subscription launcher selects the probed directory and retains proxy routing")
    let proxy = try UsageQueryProxy(host: "127.0.0.1", port: 9876)
    let endpoint = CLITerminalLaunch.traceEndpoints[0]
    for (output, expected) in [
        (BoundedCLICommand.Output(status: 0, text: "loc=SG\n200", timedOut: false), "SG"),
        (.init(status: 0, text: "loc=US\n200", timedOut: false), "US"),
        (.init(status: 0, text: "loc=SG\n302", timedOut: false), nil),
        (.init(status: 56, text: "", timedOut: false), nil)
    ] {
        let country = await CLITerminalLaunch.traceCountry(endpoint: endpoint, proxy: proxy) { arguments in
            precondition(arguments.contains(proxy.url) && arguments.suffix(1) == [endpoint])
            precondition(arguments.contains("--noproxy") && !arguments.contains("--location"))
            return output
        }
        require(country == expected, "the terminal route probe preserves actual country, including a mismatch, and rejects redirects and errors")
    }
    let command = try CLITerminalLaunch.script(binding: first, executable: URL(fileURLWithPath: "/fixture/bin/claude"), home: fakeHome, proxy: proxy)
    require(!command.contains("/login") && !command.contains("/logout") && command.contains("exec /usr/bin/env") && command.contains("-u CLAUDE_ENV_FILE"),
            "launching never forces a login overwrite or logout")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-launch-fixture-" + UUID().uuidString)
    let quotedHome = root.appendingPathComponent("home with ' quote")
    try FileManager.default.createDirectory(at: quotedHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let privateCache = root.appendingPathComponent("preview-cache")
    let sharedCache = root.appendingPathComponent("original-cache")
    let old = Snapshot(fetchedAt: .distantPast)
    let verified = Snapshot(accountID: identity.accountID, organizationID: identity.organizationID, fetchedAt: Date())
    saveCache("Fixture", old, directory: sharedCache)
    require(loadCache("Fixture", directory: privateCache, legacy: sharedCache)?.identity.isComplete == false,
            "an old sample can still be displayed without pretending its identity was verified")
    saveCache("Fixture", verified, directory: privateCache)
    saveCache("Fixture", old, directory: sharedCache)
    require(loadCache("Fixture", directory: privateCache, legacy: sharedCache)?.identity.samePrincipal(as: identity) == true,
            "an original-version sample cannot overwrite the preview's verified identity")
    require(loadCache("Fixture", directory: sharedCache, legacy: sharedCache)?.identity.isComplete == false,
            "preview writes do not modify the original version's cache")
    let fakeCLI = quotedHome.appendingPathComponent("fictional-cli")
    try "#!/bin/sh\n[ -z \"$ANTHROPIC_API_KEY$CLAUDE_ENV_FILE\" ] || exit 7\n[ \"$CLAUDE_CONFIG_DIR\" = \"$EXPECTED_CLI_DIR\" ] || exit 8\n[ \"$HTTPS_PROXY:$https_proxy:$NO_PROXY:$no_proxy\" = 'http://127.0.0.1:9876:http://127.0.0.1:9876:localhost,127.0.0.1,::1:localhost,127.0.0.1,::1' ] || exit 9\nprintf fixture-ok\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
    let quotedBinding = CLIBinding(identity: identity, choice: .defaultLogin, directory: quotedHome.appendingPathComponent(".claude"))
    let launcher = root.appendingPathComponent("launch.command")
    let separate = CLIBinding(identity: identity, choice: .isolated,
        directory: try CLIBinding.directory(for: .isolated, identity: identity, home: quotedHome))
    for launchBinding in [quotedBinding, separate] {
        try CLITerminalLaunch.script(binding: launchBinding, executable: fakeCLI, home: quotedHome, proxy: proxy)
            .write(to: launcher, atomically: true, encoding: .utf8)
        let launchedFixture = try await BoundedCLICommand.run(home: quotedHome, executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [launcher.path], inherited: ["HOME": quotedHome.path, "ANTHROPIC_API_KEY": "fictional",
                "CLAUDE_ENV_FILE": "/fictional", "CLAUDE_CONFIG_DIR": "/fictional", "HTTPS_PROXY": "http://fixture.invalid:1234",
                "NO_PROXY": "*", "EXPECTED_CLI_DIR": launchBinding.choice == .isolated ? launchBinding.directory.path : ""],
            timeoutSeconds: 5, graceSeconds: 1)
        require(launchedFixture.status == 0 && launchedFixture.text == "fixture-ok",
                "both launch modes use the checked proxy, keep loopback callbacks local, and ignore stale auth overrides")
    }
    try """
    #!/bin/sh
    [ "$CLAUDE_CONFIG_DIR" = "$EXPECTED_CLI_DIR" ] || exit 11
    [ "$HTTPS_PROXY" = 'http://127.0.0.1:9876' ] || exit 12
    [ "$NO_PROXY" = 'localhost,127.0.0.1,::1' ] || exit 13
    [ "$#" = 5 ] && [ "$1" = '--setting-sources' ] && [ -z "$2" ] &&
        [ "$3 $4 $5" = 'auth login --claudeai' ] || exit 14
    printf official-login-fixture
    """.write(to: fakeCLI, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
    try CLITerminalLaunch.script(binding: separate, executable: fakeCLI, home: quotedHome, proxy: proxy, intent: .signIn)
        .write(to: launcher, atomically: true, encoding: .utf8)
    let signInFixture = try await BoundedCLICommand.run(home: quotedHome, executable: URL(fileURLWithPath: "/bin/zsh"),
        arguments: [launcher.path], inherited: ["HOME": quotedHome.path, "EXPECTED_CLI_DIR": separate.directory.path],
        timeoutSeconds: 5, graceSeconds: 1)
    require(signInFixture.status == 0 && signInFixture.text == "official-login-fixture",
            "the separate sign-in launcher runs only native auth in the selected directory through the checked proxy")
    let cacheTime = Date().addingTimeInterval(-60)
    func usageDocument(for owner: CLIIdentity, used: Double) throws -> Data {
        try CLIJSON.encode(["oauthAccount": ["accountUuid": owner.accountID!, "organizationUuid": owner.organizationID!],
            "cachedUsageUtilization": ["accountUuid": owner.accountID!, "fetchedAtMs": cacheTime.timeIntervalSince1970 * 1000,
                "utilization": ["five_hour": ["utilization": used]]]])
    }
    let cacheDirectory = try CLIBinding.directory(for: .isolated, identity: identity, home: quotedHome)
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let isolatedDocument = cacheDirectory.appendingPathComponent(".claude.json")
    let defaultDocument = quotedHome.appendingPathComponent(".claude.json")
    let accountAUsage = try usageDocument(for: identity, used: 17)
    let accountBUsage = try usageDocument(for: other, used: 81)
    try accountAUsage.write(to: isolatedDocument); try accountBUsage.write(to: defaultDocument)
    let sessionSentinel = cacheDirectory.appendingPathComponent("history.jsonl")
    try Data("fictional history must stay".utf8).write(to: sessionSentinel)
    let isolatedCacheBinding = CLIBinding(identity: identity, choice: .isolated, directory: cacheDirectory)
    let accountASample = try await OfficialCLIUsageReader.readBoundCache(home: quotedHome, binding: isolatedCacheBinding, expected: identity)
    require(accountASample?.identity.samePrincipal(as: identity) == true && accountASample?.session?.used == 17,
            "account A's separate cache is read instead of account B's default cache")
    require(abs(accountASample!.fetchedAt.timeIntervalSince(cacheTime)) < 0.001,
            "reading an associated cache retains the official sampling time")
    let accountBBinding = CLIBinding(identity: other, choice: .defaultLogin, directory: quotedHome.appendingPathComponent(".claude"))
    let accountBSample = try await OfficialCLIUsageReader.readBoundCache(home: quotedHome, binding: accountBBinding, expected: other)
    require(accountBSample?.session?.used == 81, "the existing default cache remains independently available")
    try accountBUsage.write(to: isolatedDocument)
    let rejectedSample = try await OfficialCLIUsageReader.readBoundCache(home: quotedHome, binding: isolatedCacheBinding, expected: identity)
    require(rejectedSample == nil, "another identity inside a selected directory cannot be adopted as account A's usage")
    let defaultAfterRead = try Data(contentsOf: defaultDocument)
    let historyAfterRead = try String(contentsOf: sessionSentinel)
    require(defaultAfterRead == accountBUsage && historyAfterRead == "fictional history must stay",
            "associated usage reads do not modify the default account record or session history")
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
