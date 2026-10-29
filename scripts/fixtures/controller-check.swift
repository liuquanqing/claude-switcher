import Foundation
import SwiftUI
import SwitcherCore

actor FixtureGuardWorker: GuardWorking {
 let files: SafetyFiles
 var registeredValue = true
 var failure: String?
 init(files: SafetyFiles) { self.files = files }
 func registered() async -> Bool { try? await Task.sleep(nanoseconds: 40_000_000); return registeredValue }
 func setFailure(_ value: String?) { failure = value }
 func enable(_ config: SafetyConfig) throws {
  if let failure { throw SafetyError(failure) }
  try files.save(config, to: files.configURL)
 }
 func disable() throws {
  if let failure { throw SafetyError(failure) }
  try files.save(SafetyConfig(enabled: false), to: files.configURL); registeredValue = false
 }
}

@MainActor final class FixtureCLIProbe {
 private var pending: CheckedContinuation<CLIStatusPresentation, Never>?
 private var started: CheckedContinuation<Void, Never>?

 func run() async -> CLIStatusPresentation {
  await withCheckedContinuation { continuation in
   pending = continuation
   started?.resume(); started = nil
  }
 }
 func waitUntilStarted() async {
  if pending != nil { return }
  await withCheckedContinuation { started = $0 }
 }
 func complete(_ result: CLIStatusPresentation) {
  guard let continuation = pending else { preconditionFailure("Fixture probe must start before completion") }
  pending = nil
  continuation.resume(returning: result)
 }
}

@main struct ControllerChecks {
 @MainActor static func main() async throws {
  var checks = 0
  func require(_ value: Bool, _ description: String) { precondition(value, description); checks += 1 }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("controller-fixture-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = SafetyFiles(directory: root.appendingPathComponent("state"))
  let config = SafetyConfig(enabled: true)
  try files.save(config, to: files.configURL)
  try files.save(GuardReceipt(config: config, decision: SafetyDecision(.allowed)), to: files.receiptURL)
  let worker = FixtureGuardWorker(files: files)
  let liveBranch = ProtectionController(testFiles: files, worker: worker)
  var uiResponsive = false
  Task { @MainActor in uiResponsive = true }
  try await Task.sleep(nanoseconds: 100_000_000)
  require(uiResponsive && liveBranch.guardOnline, "service lookup must not block main actor")
  await worker.setFailure("fixture: configuration is read only")
  liveBranch.country = "JP"
  await liveBranch.enable()
  require(liveBranch.operationError == "fixture: configuration is read only", "live failure is surfaced")
  require(liveBranch.enabled && liveBranch.guardOnline && liveBranch.activeCountry == "SG", "failed save preserves actual live state")
  liveBranch.clearOperationError()
  require(liveBranch.operationError == nil && liveBranch.enabled, "dismiss is presentation only")
  liveBranch.disable()
  try await Task.sleep(nanoseconds: 100_000_000)
  require(liveBranch.operationError != nil && liveBranch.enabled, "failed stop does not fake off")
  await worker.setFailure(nil)
  liveBranch.country = "SG"; await liveBranch.enable()
  require(liveBranch.operationError == nil, "successful retry clears operation error")

  let demo = ProtectionController(demo: true)
  require(!demo.hasUnsavedChanges, "saved demo settings begin clean")
  demo.country = " sg "; require(!demo.hasUnsavedChanges, "normalized country is not an unsaved edit")
  demo.mode = .auto; require(demo.hasUnsavedChanges, "proxy mode edit requires save")
  demo.mode = .shadowrocket; demo.country = "SG"
  let original = demo.lastDecision
  demo.country = "ZZ"; await demo.enable()
  require(demo.operationError != nil && demo.lastDecision == original && demo.guardOnline, "invalid input cannot replace runtime health")
  demo.clearOperationError(); demo.disable(); demo.country = "SG"; await demo.checkNow()
  require(!demo.enabled && !demo.guardOnline && demo.lastCheckReport?.passed == true, "readonly result cannot enable protection")
  demo.country = "JP"; await demo.checkNow()
  require(demo.activeCountry == "SG" && demo.lastCheckReport?.passed == false, "draft target is not saved target")
  demo.country = "ZZ"; await demo.checkNow()
  require(demo.lastCheckReport?.observation == nil && demo.lastCheckReport?.validationMessage != nil, "invalid diagnostic has no fake observation")

  let store = Store(demo: true)
  let before = store.profiles[0].snapshot?.email
  require(store.cliStatus == .matched, "demo begins with explicit matching fixture")
  await store.switchTo("Business")
  require(store.current == "Business" && store.cliProfile == "Business" && store.cliStatus == .matched, "demo follows desktop and default login")
  require(store.cliEmail == store.profiles.first(where: {$0.name == "Business"})?.snapshot?.email, "fixture login identity follows account")
  await store.switchTo("Personal")
  require(store.cliEmail == before, "demo round trip returns to source fixture")
  let retainedCLI = store.cliProfile
  let retainedEmail = store.cliEmail
  store.desktopOnlyOffer = DesktopOnlySwitchOffer(source: "Personal", target: "Business", reason: "fixture legacy login")
  await store.confirmDesktopOnlySwitch()
  require(store.current == "Business" && store.cliProfile == retainedCLI && store.cliEmail == retainedEmail, "explicit desktop-only exception leaves CLI unchanged")
  require(store.cliStatus == .unverified && store.desktopOnlyOffer == nil, "desktop-only choice requires fresh verification, not a demo-only success")
  await store.verifyDefaultCLI()
  require(store.cliStatus == .different && store.cliProfile == retainedCLI, "explicit verify reveals mismatch without changing saved login")
  store.desktopOnlyOffer = DesktopOnlySwitchOffer(source: "Personal", target: "Side Project", reason: "stale fixture")
  await store.confirmDesktopOnlySwitch()
  require(store.current == "Business" && store.cliProfile == retainedCLI, "stale desktop-only choice cannot switch")
  store.desktopOnlyOffer = DesktopOnlySwitchOffer(source: "Business", target: "Personal", reason: "blocked fixture")
  store.protection.disable()
  await store.confirmDesktopOnlySwitch()
  require(store.current == "Business" && store.cliProfile == retainedCLI, "desktop-only choice still requires network and guard gate")
  await store.moveTerminal(to: "Business")
  require(store.cliProfile == retainedCLI, "manual CLI synchronization is blocked while protection is off")
  await store.protection.enable()
  await store.moveTerminal(to: "Business")
  require(store.cliProfile == "Business" && store.cliStatus == .matched, "manual synchronization follows the CLI gate")
  let credentialsRoot = root.appendingPathComponent("isolated-default-cli")
  try FileManager.default.createDirectory(at: credentialsRoot, withIntermediateDirectories: true)
  let credentialsURL = credentialsRoot.appendingPathComponent(".credentials.json")
  let fakeOAuth = try CLIJSON.encode(["accessToken": "fixture-file-token", "refreshToken": "fixture-refresh"])
  try CLIPrivateFile.write(CLIJSON.replacing(nil, key: "claudeAiOauth", with: fakeOAuth), to: credentialsURL)
  var isolatedSecrets: [String: Data] = [:]
  let fileLogin = NativeCLIStorage(identity: credentialsRoot.appendingPathComponent("identity.json"), marker: credentialsRoot.appendingPathComponent("marker"), credentialFile: credentialsURL,
      secretReader: { isolatedSecrets[$0 + "/" + $1] }, secretWriter: { isolatedSecrets[$0 + "/" + $1] = $2 })
  require(try CLIJSON.field(fileLogin.readCredentials(), key: "claudeAiOauth") == fakeOAuth, "native adapter reads only fixture file credentials with injected Keychain")
  try fileLogin.writeBackup("Fixture", data: Data("{}".utf8))
  require(try fileLogin.readBackup("Fixture") == Data("{}".utf8), "file-sourced login backup uses isolated secret repository")
  let replacement = try CLIJSON.replacing(nil, key: "claudeAiOauth", with: CLIJSON.encode(["accessToken": "fixture-replacement"]))
  try fileLogin.writeCredentials(replacement)
  require(try CLIPrivateFile.read(credentialsURL) == replacement, "native adapter updates default file source without creating primary credentials")
  require(!isolatedSecrets.keys.contains { $0.hasPrefix(cliService + "/") }, "file path does not silently move login into another store")
  let identityFile = root.appendingPathComponent("isolated-identity.json")
  let markerFile = root.appendingPathComponent("isolated-marker")
  let fileAdapter = NativeCLIStorage(identity: identityFile, marker: markerFile)
  require(try fileAdapter.readIdentityDocument() == nil, "genuinely missing identity file")
  try fileAdapter.writeIdentityDocument(Data("{}".utf8)); try fileAdapter.writeMarker("fixture")
  require(try fileAdapter.readMarker() == "fixture", "marker adapter in temporary root")
  require((try FileManager.default.attributesOfItem(atPath: identityFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "identity document remains private")
  try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: identityFile.path)
  var denied = false
  do { _ = try fileAdapter.readIdentityDocument() } catch { denied = true }
  require(denied, "permission denial is not missing login")
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityFile.path)
  try fileAdapter.writeIdentityDocument(nil); try fileAdapter.writeMarker(nil)
  require(try fileAdapter.readIdentityDocument() == nil && fileAdapter.readMarker() == nil, "temporary files can be restored to absent")
  let desktopFixture = root.appendingPathComponent("desktop-fixture")
  try FileManager.default.createDirectory(at: desktopFixture, withIntermediateDirectories: true)
  let sourceConfig = desktopFixture.appendingPathComponent("config.json")
  let reader = DesktopTokenReader(secretProvider: { Data("fixture-secret".utf8) })
  require(try await reader.read(directory: desktopFixture) == nil, "missing desktop config is explicit absence")
  try JSONSerialization.data(withJSONObject: ["oauth:tokenCacheV2": "djEwSrospCyl4cv7QqCVRvA38J7NacG9Jc+5WvvH+TOD+ATgAMH/Y7vHThEbpksvJ59iP+LaVgiXDyT60Xm3TxOzEtrN2HFDwlxIST89w6N2i/CxzIVHueysMVH0E8mQuCZp"]).write(to: sourceConfig)
  require(try await reader.read(directory: desktopFixture) == "fixture-desktop-token", "retained Electron v10 format matches independent OpenSSL fixture")
  try JSONSerialization.data(withJSONObject: ["oauth:tokenCacheV2": "djEw"]).write(to: sourceConfig)
  var malformedRejected = false
  do { _ = try await reader.read(directory: desktopFixture) } catch { malformedRejected = true }
  require(malformedRejected, "empty ciphertext rejected before buffer access")
  try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sourceConfig.path)
  var desktopDenied = false
  do { _ = try await reader.read(directory: desktopFixture) } catch { desktopDenied = true }
  require(desktopDenied, "unreadable desktop data is not signed out")
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceConfig.path)
  let transferFixture = try SessionTransferDemo.environment()
  defer { try? FileManager.default.removeItem(at: transferFixture.1) }
  let transferStore = Store(demo: true)
  let transfer = SessionTransferController(store: transferStore, testEnvironment: transferFixture.0)
  func settled(_ controller: SessionTransferController) async throws {
   for _ in 0..<100 {
    await Task.yield()
    if !controller.isWorking { return }
    try await Task.sleep(nanoseconds: 5_000_000)
   }
   preconditionFailure("transfer fixture did not settle")
  }
  await transfer.refresh()
  require(transfer.rows.contains { $0.title == "设置面板排版整理" && $0.cwd == "/demo/atlas" }, "native controller exposes concrete session title/project")
  require(transfer.rows.first { $0.id == "local_ui.json" }?.selectable == true && !transfer.updateExisting, "native default adds only")
  transfer.setPicked("local_ui.json", selected: true)
  await transfer.copySelected(); try await settled(transfer)
  require(transfer.lastOperation?.canUndo == true && transfer.confirmation == nil, "add-only native action uses actual temp engine without extra dialog")
  transfer.showBackup(); try await settled(transfer)
  require(transfer.backupItems.first?.title == "设置面板排版整理" && transfer.backupItems.first?.cwd == "/demo/atlas", "backup preview verifies actual temp files before showing concrete session metadata")
  transfer.dismissBackup()
  require(transfer.rows.first { $0.id == "local_ui.json" }?.selectable == false, "copied session is immediately deduplicated")
  transfer.requestUndo(); transfer.dismissConfirmation(); await transfer.confirmAction(); try await settled(transfer)
  require(transfer.lastOperation?.canUndo == false && transfer.rows.first { $0.id == "local_ui.json" }?.selectable == true, "native alert dismissal cannot consume pending undo")
  transfer.setUpdates(true); try await settled(transfer)
  transfer.setPicked("local_api.json", selected: true)
  let targetIndex = transferFixture.0.endpoints.first { $0.id == "profile:Personal" }!.root.appendingPathComponent("claude-code-sessions/account-personal/org-personal/local_api.json")
  let progressBefore = try Data(contentsOf: targetIndex)
  await transfer.copySelected()
  let pendingTargetBytes = try Data(contentsOf: targetIndex)
  require(transfer.confirmation != nil && pendingTargetBytes == progressBefore, "covering update requires explicit confirmation before temp write")
  transfer.cancelConfirmation(); await transfer.confirmAction(); try await settled(transfer)
  require(try Data(contentsOf: targetIndex) == progressBefore, "cancelled confirmation cannot later commit")
  transfer.setPicked("local_api.json", selected: true); await transfer.copySelected()
  transfer.dismissConfirmation(); await transfer.confirmAction(); try await settled(transfer)
  let progressAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: targetIndex)) as! [String: Any]
  require(progressAfter["completedTurns"] as? Int == 28, "native confirmed update reaches same file engine")
  let unresolvedID = transfer.lastOperation!.id
  let receiptURL = transferFixture.0.backups.appendingPathComponent(unresolvedID + "/receipt.json")
  var unresolvedDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
  unresolvedDocument["state"] = "recoveryRequired"
  try JSONSerialization.data(withJSONObject: unresolvedDocument).write(to: receiptURL)
  await transfer.refresh()
  require(transfer.lastOperation?.needsRecovery == true && !transfer.canCopy, "unresolved journal is shown and blocks another copy")
  transfer.requestKeepCurrent(); transfer.cancelConfirmation(); await transfer.confirmAction()
  let stillUnresolved = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
  require(stillUnresolved["state"] as? String == "recoveryRequired", "cancel keep-current leaves journal unresolved")
  let targetBeforePreserve = try Data(contentsOf: targetIndex)
  transfer.requestKeepCurrent(); transfer.dismissConfirmation(); await transfer.confirmAction(); try await settled(transfer)
  let targetAfterPreserve = try Data(contentsOf: targetIndex)
  require(transfer.lastOperation?.needsRecovery == false && transfer.statusMessage?.contains("未执行恢复") == true && targetAfterPreserve == targetBeforePreserve, "explicit keep-current ends only journal and reports no recovery")
  transfer.setTarget("api"); try await settled(transfer)
  require(transfer.targetSpaces.count == 2 && transfer.targetSpaceID.isEmpty && transfer.picked.isEmpty, "API multi-space never guesses or retains old selection")
  let blockedFixture = try SessionTransferDemo.environment()
  defer { try? FileManager.default.removeItem(at: blockedFixture.1) }
  let blockedEnv = SessionTransferEnvironment(endpoints: blockedFixture.0.endpoints, activeEndpointIDs: ["profile:Personal"], transcripts: blockedFixture.0.transcripts, backups: blockedFixture.0.backups)
  let blockedTransfer = SessionTransferController(store: Store(demo: true), testEnvironment: blockedEnv, worker: SessionTransferWorker(runningProbe: { true }))
  await blockedTransfer.refresh(); blockedTransfer.setPicked("local_ui.json", selected: true); await blockedTransfer.copySelected()
  require(blockedTransfer.errorMessage?.contains("自行退出 Claude") == true && !FileManager.default.fileExists(atPath: blockedEnv.backups.path), "fake live-desktop gate prevents backup and target writes without querying real processes")
  let intentFixture = try SessionTransferDemo.environment()
  defer { try? FileManager.default.removeItem(at: intentFixture.1) }
  let intentController = SessionTransferController(store: Store(demo: true), testEnvironment: intentFixture.0,
   worker: SessionTransferWorker(runningProbe: { false }, beforePlan: { try? await Task.sleep(nanoseconds: 150_000_000) }))
  await intentController.refresh(); intentController.setPicked("local_ui.json", selected: true)
  let oldSourceID = intentController.sourceID, oldTargetID = intentController.targetID
  let inFlightCopy = Task { @MainActor in await intentController.copySelected() }
  for _ in 0..<50 { if intentController.isWorking { break }; await Task.yield() }
  intentController.setSource("api"); intentController.setTarget("api"); intentController.setUpdates(true)
  require(intentController.sourceID == oldSourceID && intentController.targetID == oldTargetID && !intentController.updateExisting, "in-flight planning freezes source target and update intent")
  await intentController.confirmAction()
  require(intentController.errorMessage?.contains("重新确认") == true && intentController.confirmation == nil, "busy confirmation reports failure and discards stale pending intent")
  await intentController.refresh()
  await inFlightCopy.value
  require(!FileManager.default.fileExists(atPath: intentFixture.0.backups.path) && intentController.statusMessage?.contains("重新复制") == true, "refreshed epoch discards the old asynchronous plan before any backup or write")
  let inactiveFixture = try SessionTransferDemo.environment()
  defer { try? FileManager.default.removeItem(at: inactiveFixture.1) }
  let inactiveEnv = SessionTransferEnvironment(endpoints: inactiveFixture.0.endpoints, activeEndpointIDs: ["api"], transcripts: inactiveFixture.0.transcripts, backups: inactiveFixture.0.backups)
  let inactiveController = SessionTransferController(store: Store(demo: true), testEnvironment: inactiveEnv,
   worker: SessionTransferWorker(runningProbe: { throw SafetyError("probe must not run for parked target") }))
  await inactiveController.refresh(); inactiveController.setPicked("local_ui.json", selected: true); await inactiveController.copySelected()
  require(inactiveController.lastOperation?.canUndo == true, "parked target does not query or stop a running desktop")
  let exportFixture = try SessionTransferDemo.environment()
  defer { try? FileManager.default.removeItem(at: exportFixture.1) }
  let exportController = SessionTransferController(store: Store(demo: true), testEnvironment: exportFixture.0, commandURL: URL(fileURLWithPath: "/usr/bin/true"))
  await exportController.refresh(); exportController.setPicked("local_ui.json", selected: true)
  let directInstructions = await exportController.generateInstructions()
  require(directInstructions?.contains("plan --request") == true && exportController.handoffInformation == nil && exportController.confirmation == nil, "direct instruction generation returns text without presenting any modal")
  require(!FileManager.default.fileExists(atPath: exportFixture.0.backups.path) && exportController.picked == ["local_ui.json"], "direct generation never starts import or consumes selected sessions")
  await exportController.exportInstructions()
  require(exportController.handoffInformation?.contains("plan --request") == true && exportController.handoffInformation?.contains("apply --request") == true, "handoff contains commands for the explicitly injected fixture helper without executing it")
  require(!FileManager.default.fileExists(atPath: exportFixture.0.backups.path) && exportController.picked.contains("local_ui.json"), "export never starts copy or consumes selection")
  exportController.dismissHandoff(); require(exportController.handoffInformation == nil, "closing handoff is presentation only")
  let requestFolder = exportFixture.1.appendingPathComponent("session-transfer-requests")
  let exported = try FileManager.default.contentsOfDirectory(at: requestFolder, includingPropertiesForKeys: nil)
  let request = try SessionTransferRequest.load(from: exported[0]); _ = try request.checkedPlan()
  require(request.selected == ["local_ui.json"] && request.updateExisting == false, "local request preserves exact selected add-only intent")
  let missingHelperController = SessionTransferController(store: Store(demo: true), testEnvironment: exportFixture.0, commandURL: exportFixture.1.appendingPathComponent("missing-helper"))
  await missingHelperController.refresh()
  let missingInstructions = await missingHelperController.generateInstructions()
  require(missingInstructions == nil && missingHelperController.errorMessage?.contains("未找到备用复制工具") == true && missingHelperController.handoffInformation == nil, "failed direct generation returns no clipboard text and no preview")
  require(!missingHelperController.isWorking && missingHelperController.picked == ["local_ui.json"], "failure resets processing and preserves the user's selection")
  for scenario in ["recovery", "conflict"] {
   let fixture = try SessionTransferDemo.environment(scenario: scenario)
   defer { try? FileManager.default.removeItem(at: fixture.1) }
   let controller = SessionTransferController(store: Store(demo: true), testEnvironment: fixture.0)
   await controller.refresh(); require(controller.lastOperation?.needsRecovery == true, "native QA scenario has a real isolated unresolved journal")
   controller.requestRecovery(); controller.dismissConfirmation(); await controller.confirmAction()
   if scenario == "recovery" {
    require(controller.lastOperation?.state == .restored, "native recoverable fixture reaches restored with actual temp engine")
   } else {
    require(controller.errorMessage?.contains("新进展") == true && controller.lastOperation?.needsRecovery == true, "native conflict fixture remains locked and reports preserved external progress")
    controller.requestKeepCurrent(); controller.cancelConfirmation()
    require(controller.lastOperation?.needsRecovery == true, "cancel exception cannot unlock recovery")
    controller.requestKeepCurrent(); controller.dismissConfirmation(); await controller.confirmAction()
    require(controller.lastOperation?.state == .preserved, "explicit exception closes journal without claiming recovery")
   }
  }
  let navigationStore = Store(demo: true); let previousAccount = navigationStore.current
  var returned = 0; navigationStore.onShowAccounts = { returned += 1 }
  navigationStore.returnToAccounts()
  require(returned == 1 && navigationStore.current == previousAccount, "return navigation calls panel callback without switching accounts")
  let selectionFixture = try SessionTransferDemo.environment()
  defer { try? FileManager.default.removeItem(at: selectionFixture.1) }
  let selection = SessionTransferController(store: Store(demo: true), testEnvironment: selectionFixture.0)
  await selection.refresh()
  require(selection.visibleRows.count == 4 && selection.visibleRows.filter(\.selectable).count == 1, "four visible sessions can legitimately contain only one selectable add")
  require(selection.picked == ["local_ui.json"], "first valid load defaults to missing sessions only, without selecting updates")
  selection.selectAllVisible()
  require(selection.picked.isEmpty, "select-all on initially selected eligible rows clears them")
  selection.selectAllVisible()
  require(selection.picked == ["local_ui.json"], "select-all never unlocks existing or conflicting sessions")
  selection.setPicked("local_ui.json", selected: false); await selection.refresh()
  require(selection.picked.isEmpty, "normal refresh never silently reselects a user's deselection")
  selection.setSource(selection.sourceID); selection.setTarget(selection.targetID)
  selection.setSourceSpace(selection.sourceSpaceID); selection.setTargetSpace(selection.targetSpaceID)
  require(selection.picked.isEmpty && !selection.isWorking, "reselecting unchanged scope cannot reset explicit user deselection")
  selection.setUpdates(true); try await settled(selection)
  selection.setPicked("local_ui.json", selected: true)
  selection.selectAllVisible()
  require(selection.picked == ["local_ui.json", "local_api.json"], "mixed selection becomes all eligible, without selecting ahead or conflicting rows")
  selection.query = "接口"
  selection.selectAllVisible()
  require(selection.picked == ["local_ui.json"], "filtered select-all clears only its visible eligible rows and retains hidden selection")
  selection.selectAllVisible()
  require(selection.picked == ["local_ui.json", "local_api.json"], "filtered select-all adds its visible eligible rows to existing hidden selection")
  selection.query = "no-such-session"
  selection.selectAllVisible()
  require(selection.picked == ["local_ui.json", "local_api.json"], "empty result select-all changes nothing")
  selection.setUpdates(false); try await settled(selection)
  require(selection.picked == ["local_ui.json"], "turning updates off removes only update selections")
  selection.setTarget("api"); try await settled(selection)
  require(selection.picked.isEmpty, "changing destination clears selection instead of copying an old scope")
  selection.query = ""
  selection.setTargetSpace(selection.targetSpaces[0].id); try await settled(selection)
  require(selection.picked.count == 4 && selection.rows.allSatisfy { $0.kind == .add }, "new explicitly chosen API space defaults to missing sessions after resolving that scope")
  var usageProfile = Profile(name: "missing", snapshot: nil, signedIn: true)
  require(usageProfile.usageState == .notRequested, "missing usage data is not automatically loading")
  usageProfile.blockUsageRefresh("fixture gate denied")
  require(usageProfile.usageState == .blocked && usageProfile.snapshot == nil, "blocked request ends in explicit blocked state without a fake spinner")
  usageProfile.beginUsageRefresh()
  require(usageProfile.usageState == .loading && usageProfile.error == nil, "loading begins only when a request is actually scheduled")
  usageProfile.finishUsageRefresh(.failure(SafetyError("fixture timeout")))
  require(usageProfile.usageState == .failed && usageProfile.error == "fixture timeout", "request failure cannot remain loading")
  let freshSnapshot = Snapshot(fetchedAt: Date())
  usageProfile.finishUsageRefresh(.success(freshSnapshot))
  require(usageProfile.usageState == .loaded && usageProfile.live, "successful live request is explicitly distinguished from cache")
  usageProfile.blockUsageRefresh("fixture protection unavailable")
  require(usageProfile.snapshot != nil && !usageProfile.live && usageProfile.usageState == .blocked, "blocked refresh retains cache but does not claim live data")
  usageProfile.beginUsageRefresh(); usageProfile.finishUsageRefresh(nil)
  require(!usageProfile.signedIn && usageProfile.usageState == .notRequested, "confirmed absence of login terminates loading")
  let languageStore = Store(demo: true)
  let languageController = SessionTransferController(store: languageStore, testEnvironment: selectionFixture.0)
  require(languageStore.importLanguage == "zh" && languageController.language == "zh", "demo language is isolated and starts in Chinese")
  languageStore.setImportLanguage("en")
  require(languageController.language == "en", "main preferences propagate to an existing import controller")
  languageStore.setImportLanguage("invalid")
  require(languageStore.importLanguage == "en" && languageController.language == "en", "invalid language cannot replace the active preference")
  let probeHome = root.appendingPathComponent("cli-report-home")
  let probeExecutable = probeHome.appendingPathComponent(".local/bin/claude")
  try FileManager.default.createDirectory(at: probeExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
  func setProbe(_ value: [String: Any], code: Int) throws {
   let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
   let script = "#!/bin/sh\nprintf '%s' " + SessionTransferRequest.shellQuote(json) + "\nexit \(code)\n"
   try script.write(to: probeExecutable, atomically: true, encoding: .utf8)
   try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probeExecutable.path)
  }
  try setProbe(["loggedIn": true, "authMethod": "claude.ai", "configDirectory": probeHome.appendingPathComponent(".claude").path, "email": "fake@example.test", "orgId": "fixture-org"], code: 0)
  let reported = try await CLIStatusReader.read(home: probeHome)
  require(reported.loggedIn && reported.usesConfigurationDirectory(probeHome.appendingPathComponent(".claude")), "readonly status worker invokes only an executable in the fake home and parses the report")
  try setProbe(["loggedIn": false, "authMethod": "none", "configDirectory": probeHome.appendingPathComponent(".claude").path], code: 1)
  let signedOutReport = try await CLIStatusReader.read(home: probeHome)
  require(!signedOutReport.loggedIn, "explicit logged-out report is distinguished from unsupported storage")
  try setProbe(["loggedIn": true, "authMethod": "claude.ai", "configDirectory": probeHome.appendingPathComponent(".claude").path], code: 1)
  var inconsistentReportRejected = false
  do { _ = try await CLIStatusReader.read(home: probeHome) } catch { inconsistentReportRejected = true }
  require(inconsistentReportRejected, "status exit code and reported login must agree")
  let absentProtectionFiles = SafetyFiles(directory: root.appendingPathComponent("absent-protection"))
  let absentProtectionWorker = FixtureGuardWorker(files: absentProtectionFiles)
  try await absentProtectionWorker.disable()
  try FileManager.default.removeItem(at: absentProtectionFiles.directory)
  let absentProtection = ProtectionController(testFiles: absentProtectionFiles, worker: absentProtectionWorker)
  let absentDecision = await absentProtection.preflight()
  require(absentDecision.reason == .disabled, "first-time missing configuration with no registered guard is not misreported as malformed")
  let quietStore = Store(demo: true)
  let priorEmail = quietStore.cliEmail, priorCheckedAt = quietStore.cliStatusCheckedAt
  let quietProbe = FixtureCLIProbe()
  let quietRefresh = Task { @MainActor in
   await quietStore.updateCLIStatus { await quietProbe.run() }
  }
  await quietProbe.waitUntilStarted()
  require(quietStore.cliStatusRefreshing && quietStore.cliStatus == .matched, "background refresh retains the last completed conclusion while evaluating")
  require(quietStore.cliEmail == priorEmail && quietStore.cliStatusCheckedAt == priorCheckedAt, "intermediate evaluation cannot replace identity or completion time")
  quietProbe.complete(CLIStatusPresentation(status: .different, profile: "Business", email: "new@example.test", detail: "fixture completed"))
  await quietRefresh.value
  require(!quietStore.cliStatusRefreshing && quietStore.cliStatus == .different && quietStore.cliEmail == "new@example.test", "completed result publishes the new conclusion and identity together")
  await quietStore.updateCLIStatus { CLIStatusPresentation(status: .unverified, detail: "fixture failed") }
  require(quietStore.cliStatus == .unverified && quietStore.cliProfile == nil, "failed or unknown completion cannot retain a green match")
  let profileProbe = FixtureCLIProbe()
  let changedContext = Task { @MainActor in
   await quietStore.updateCLIStatus { await profileProbe.run() }
  }
  await profileProbe.waitUntilStarted(); quietStore.current = "Business"
  profileProbe.complete(CLIStatusPresentation(status: .matched, profile: "Personal", email: "old@example.test"))
  await changedContext.value
  require(quietStore.cliStatus == .unverified && quietStore.cliEmail == nil && quietStore.cliStatusCheckedAt == nil, "a changed desktop profile rejects an in-flight old match")
  let scopeProbe = FixtureCLIProbe()
  let invalidatedContext = Task { @MainActor in
   await quietStore.updateCLIStatus { await scopeProbe.run() }
  }
  await scopeProbe.waitUntilStarted(); quietStore.invalidateCLIStatus()
  scopeProbe.complete(CLIStatusPresentation(status: .matched, profile: "Business"))
  await invalidatedContext.value
  require(quietStore.cliStatus == .unverified && quietStore.cliStatusCheckedAt == nil, "a scope/context invalidation rejects an in-flight old result even if the profile name stayed the same")
  await quietStore.updateCLIStatus { CLIStatusPresentation(status: .unverified, email: "api-cli@example.test", standaloneVerified: true) }
  require(quietStore.cliStandaloneVerified && quietStore.cliStatus != .matched, "verified standalone CLI identity is distinct from a desktop match")
  quietStore.invalidateCLIStatus()
  require(!quietStore.cliStandaloneVerified && quietStore.cliEmail == nil, "context invalidation clears standalone verification as well as identity")
  let passiveStore = Store(demo: true), passiveTime = Date()
  passiveStore.lastRefresh = passiveTime
  for _ in 0..<3 { passiveStore.panelWillOpen() }
  require(passiveStore.lastRefresh == passiveTime && !passiveStore.cliStatusRefreshing && passiveStore.cliStatus == .matched, "opening a panel is passive and never starts a full CLI refresh")
  print("PASS: \(checks) controller/store checks; temporary files and fixture worker only. No live credential/service actions.")
 }
}
