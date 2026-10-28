import XCTest
@testable import SwitcherCore

final class ConfigurationScopeTests: FixtureTest {
    func testCanonicalProfileIdentityAndAliases() {
        let nested = CLIIdentity.profile(["account": ["uuid": "a", "email": "a@example.test"], "organization": ["uuid": "org"]])
        let alternate = CLIIdentity.profile(["account_uuid": "a", "organization_uuid": "org", "email_address": "a@example.test"])
        XCTAssertTrue(nested.isComplete); XCTAssertTrue(nested.samePrincipal(as: alternate))
    }
    func testConflictingProfileIDsRemainUnknown() {
        let identity = CLIIdentity.profile(["account": ["uuid": "a"], "accountUuid": "other", "organization": ["uuid": "org"]])
        XCTAssertFalse(identity.isComplete)
        XCTAssertFalse(CLIIdentity(accountID: "  ", organizationID: "org", email: nil).isComplete)
    }
    func testUUIDCaseDoesNotChangeIdentityButOrganizationDoes() {
        let a = CLIIdentity(accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", organizationID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", email: "same@example.test")
        let b = CLIIdentity(accountID: a.accountID!.uppercased(), organizationID: a.organizationID!.uppercased(), email: "other@example.test")
        XCTAssertTrue(a.samePrincipal(as: b))
        XCTAssertFalse(a.samePrincipal(as: CLIIdentity(accountID: a.accountID, organizationID: "other", email: a.email)))
    }
    func testDefaultSubscriptionHasNoOverride() throws {
        let result = AuthenticationConfiguration.inspect(environment: [:], documents: [try CLIJSON.encode([:])])
        XCTAssertTrue(result.allowsSubscriptionMutation)
    }
    func testAPIEnvironmentIsClassifiedWithoutReturningItsContents() {
        let result = AuthenticationConfiguration.inspect(environment: ["ANTHROPIC_AUTH_TOKEN": "fixture-secret"], documents: [])
        XCTAssertTrue(result.otherAuthentication); XCTAssertFalse(result.allowsSubscriptionMutation)
        XCTAssertFalse(result.explanation?.contains("fixture-secret") == true)
    }
    func testFalseCloudFlagsDoNotOverrideSubscription() throws {
        let result = AuthenticationConfiguration.inspect(environment: ["CLAUDE_CODE_USE_BEDROCK": "0"],
            documents: [try CLIJSON.encode(["env": ["CLAUDE_CODE_USE_VERTEX": "false"]])])
        XCTAssertTrue(result.allowsSubscriptionMutation)
        XCTAssertTrue(AuthenticationConfiguration.inspect(environment: ["CLAUDE_CODE_USE_FOUNDRY": "1"], documents: []).otherAuthentication)
    }
    func testSettingsHelperAndEnvironmentOverridesAreDetected() throws {
        for object: [String: Any] in [["apiKeyHelper": "fixture-command"], ["primaryApiKey": "fixture-key"],
                                      ["env": ["ANTHROPIC_BASE_URL": "https://fixture.invalid"]], ["forceLoginMethod": "gateway"]] {
            XCTAssertTrue(AuthenticationConfiguration.inspect(environment: [:], documents: [try CLIJSON.encode(object)]).otherAuthentication)
        }
    }
    func testCustomStorageRemainsUnsupportedButDefaultFileIsEligibleForValidation() {
        XCTAssertTrue(AuthenticationConfiguration.inspect(environment: ["CLAUDE_CONFIG_DIR": "/fixture"], documents: []).unsupportedStorage)
        XCTAssertTrue(AuthenticationConfiguration.inspect(environment: [:], documents: [], fallbackPresent: true).allowsSubscriptionMutation)
    }
    func testFilePresenceDoesNotProveOrPreventSubscriptionLogin() {
        let result = AuthenticationConfiguration.inspect(environment: [:], documents: [], fallbackPresent: true)
        XCTAssertTrue(result.fileCredentialsPresent); XCTAssertFalse(result.customDirectory)
        XCTAssertNil(result.explanation)
        XCTAssertTrue(result.allowsSubscriptionMutation)
        let custom = AuthenticationConfiguration.inspect(environment: ["CLAUDE_CONFIG_DIR": "/fixture/custom"], documents: [])
        XCTAssertTrue(custom.customDirectory); XCTAssertTrue(custom.explanation?.contains("自定义 CLI 配置目录") == true)
    }
    func testMalformedOrUnreadableSettingsStopMutations() throws {
        for data in [Data("bad".utf8), try CLIJSON.encode(["env": "invalid"]), try CLIJSON.encode(["apiKeyHelper": ["invalid": true]])] {
            let result = AuthenticationConfiguration.inspect(environment: [:], documents: [data])
            XCTAssertTrue(result.malformed); XCTAssertFalse(result.allowsSubscriptionMutation)
        }
        XCTAssertFalse(AuthenticationConfiguration.inspect(environment: [:], documents: [], unreadable: true).allowsSubscriptionMutation)
    }
    func testReadingTemporaryHomeDoesNotUseRealUserOrManagedSettings() throws {
        let home = try directory("home"), cwd = try directory("home/project/nested")
        XCTAssertTrue(AuthenticationConfiguration.read(home: home, cwd: cwd, environment: [:], managedSettings: nil).allowsSubscriptionMutation)
        try writeJSON(["env": ["ANTHROPIC_AUTH_TOKEN": "fake"]], home.appendingPathComponent("project/.claude/settings.local.json"))
        XCTAssertTrue(AuthenticationConfiguration.read(home: home, cwd: cwd, environment: [:], managedSettings: nil).otherAuthentication)
        try writeJSON([:], home.appendingPathComponent(".claude/.credentials.json"))
        let result = AuthenticationConfiguration.read(home: home, cwd: cwd, environment: [:], managedSettings: nil)
        XCTAssertTrue(result.fileCredentialsPresent)
        XCTAssertTrue(result.otherAuthentication)
    }
    func testDesktopDefaultsAndConflicts() throws {
        XCTAssertEqual(DesktopModeInspector.classify([]), .subscription)
        XCTAssertEqual(DesktopModeInspector.classify([try CLIJSON.encode([:])]), .subscription)
        XCTAssertEqual(DesktopModeInspector.classify([try CLIJSON.encode(["deploymentMode": "3p"])]), .api)
        XCTAssertEqual(DesktopModeInspector.classify([try CLIJSON.encode(["deploymentMode": "1p"]), try CLIJSON.encode(["deploymentMode": "3p"])]), .unknown)
        XCTAssertEqual(DesktopModeInspector.classify([Data("bad".utf8)]), .unknown)
        XCTAssertEqual(DesktopModeInspector.classify([try CLIJSON.encode(["deploymentMode": "unexpected"])]), .unknown)
    }
    func testUnknownAndAPIUnmanagedDesktopAreNeverStopped() async {
        for scope in [DesktopProtectionScope.unknown, .api, .subscription] {
            var stopped = false
            _ = await GuardEngine.tick(config: SafetyConfig(enabled: true),
                network: NetworkObservation(proxyConnected: false, tunOnline: false, country: nil),
                stop: { stopped = true; return "closed" }, desktopScope: scope, desktopManaged: false)
            XCTAssertFalse(stopped)
        }
    }
    func testOwnedSubscriptionStopsOnBadNetworkButAPIConfigurationIsExcluded() async {
        var stops = 0
        _ = await GuardEngine.tick(config: SafetyConfig(enabled: true),
            network: NetworkObservation(proxyConnected: false, tunOnline: false, country: nil),
            stop: { stops += 1; return "closed" }, desktopScope: .subscription, desktopManaged: true)
        _ = await GuardEngine.tick(config: SafetyConfig(enabled: true),
            network: NetworkObservation(proxyConnected: true, tunOnline: true, country: "SG"),
            stop: { stops += 1; return "closed" }, desktopScope: .api, desktopManaged: true)
        XCTAssertEqual(stops, 1)
    }
    func testDesktopScopeDoesNotBecomeCLITaskGuard() {
        let config = SafetyConfig(enabled: true), network = NetworkObservation(proxyConnected: true, tunOnline: true, country: "SG")
        let receipt = GuardReceipt(config: config, decision: SafetyDecision(.allowed), desktopScope: .api)
        XCTAssertEqual(LaunchGate.evaluate(config: config, registered: true, receipt: receipt, network: network).reason, .unsupportedMode)
        XCTAssertTrue(LaunchGate.evaluate(config: config, registered: true, receipt: receipt, network: network, target: .cli).allowed)
    }
    func testFailedTerminationCannotBeShownAsReadyToOpen() {
        let config = SafetyConfig(enabled: true)
        let receipt = GuardReceipt(config: config, decision: SafetyDecision(.countryUnknown), termination: "failed")
        let result = LaunchGate.evaluate(config: config, registered: true, receipt: receipt,
                                        network: NetworkObservation(proxyConnected: true, tunOnline: true, country: "SG"))
        XCTAssertEqual(result.reason, .terminationFailed)
    }
    func testModeFileGenerationDoesNotReauthorizeAnOldProcessAfterAPIRoundTrip() throws {
        let config = folder.appendingPathComponent("Claude/claude_desktop_config.json")
        try writeJSON(["deploymentMode": "1p"], config)
        let original = DesktopModeInspector.evidence(support: folder)
        XCTAssertEqual(original.scope, .subscription); XCTAssertNotNil(original.revision)
        let session = ManagedDesktopSession(pid: 123, launchedAt: Date(), modeRevision: original.revision)
        XCTAssertTrue(session.authorizes(original))
        try Data("{\"deploymentMode\":\"3p\"}".utf8).write(to: config, options: .atomic)
        XCTAssertFalse(session.authorizes(DesktopModeInspector.evidence(support: folder)))
        try Data("{\"deploymentMode\":\"1p\"}".utf8).write(to: config, options: .atomic)
        XCTAssertFalse(session.authorizes(DesktopModeInspector.evidence(support: folder)))
    }
    func testProcessRecordRequiresSameLifetimeNotJustPID() {
        let date = Date(), record = ManagedDesktopSession(pid: 123, launchedAt: Date())
        let fixed = ManagedDesktopSession(pid: 123, launchedAt: date)
        XCTAssertTrue(fixed.matches(pid: 123, launchedAt: date))
        XCTAssertFalse(record.matches(pid: 123, launchedAt: date.addingTimeInterval(1)))
        XCTAssertFalse(fixed.matches(pid: 124, launchedAt: date))
        XCTAssertFalse(fixed.matches(pid: 123, launchedAt: nil))
    }
    func testEvenIdenticalConfigurationRewriteRequiresExplicitReadoption() throws {
        let config = folder.appendingPathComponent("Claude/claude_desktop_config.json")
        try writeJSON(["deploymentMode": "1p"], config)
        let original = DesktopModeInspector.evidence(support: folder)
        let session = ManagedDesktopSession(pid: 123, launchedAt: Date(), modeRevision: original.revision)
        let bytes = try Data(contentsOf: config)
        try bytes.write(to: config, options: .atomic)
        let rewritten = DesktopModeInspector.evidence(support: folder)
        XCTAssertEqual(rewritten.scope, .subscription)
        XCTAssertFalse(session.authorizes(rewritten))
    }
}

final class ProfileUndoTests: FixtureTest {
    func testMutationMarkerMustBePresentReadableAndAValidName() throws {
        let marker = folder.appendingPathComponent(".current")
        XCTAssertThrowsError(try ProfileTransaction.currentName(at: marker))
        try Data("A\n".utf8).write(to: marker)
        XCTAssertEqual(try ProfileTransaction.currentName(at: marker), "A")
        try Data("../other".utf8).write(to: marker)
        XCTAssertThrowsError(try ProfileTransaction.currentName(at: marker))
        try Data("A".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) }
        XCTAssertThrowsError(try ProfileTransaction.currentName(at: marker))
    }
    func testSymbolicLinkProfileParentIsNotMovedThrough() throws {
        let live = try directory("live"), realParked = try directory("realParked"), linked = folder.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: realParked)
        XCTAssertThrowsError(try ProfileTransaction(live: live, parked: linked, marker: folder.appendingPathComponent(".current")).validate(from: "A", to: "B"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }
    func testCompletedDesktopMoveCanBeUndoneAfterCLIFailure() throws {
        let live = try directory("live"), parked = try directory("parked"), marker = folder.appendingPathComponent("marker")
        try Data("source".utf8).write(to: live.appendingPathComponent("keep"))
        let target = try directory("parked/B"); try Data("target".utf8).write(to: target.appendingPathComponent("keep"))
        try Data("A".utf8).write(to: marker)
        let undo = try ProfileTransaction(live: live, parked: parked, marker: marker).activate(from: "A", to: "B")
        try undo()
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("keep")), "source")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("keep")), "target")
        XCTAssertEqual(try String(contentsOf: marker), "A")
    }
    func testUndoNewEmptyTargetRestoresMissingMarker() throws {
        let live = try directory("live"), parked = try directory("parked"), marker = folder.appendingPathComponent("marker")
        try Data("source".utf8).write(to: live.appendingPathComponent("keep"))
        let undo = try ProfileTransaction(live: live, parked: parked, marker: marker).activate(from: "A", to: "B")
        try undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.appendingPathComponent("B").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testUndoRefusesExternallyChangedDesktopMarker() throws {
        let live = try directory("live"), parked = try directory("parked"), marker = folder.appendingPathComponent("marker")
        let undo = try ProfileTransaction(live: live, parked: parked, marker: marker).activate(from: "A", to: "B")
        try Data("external".utf8).write(to: marker)
        XCTAssertThrowsError(try undo())
        XCTAssertEqual(try String(contentsOf: marker), "external")
    }
}
