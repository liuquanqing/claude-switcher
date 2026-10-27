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
  print("PASS: \(checks) controller/store checks; temporary files and fixture worker only. No live credential/service actions.")
 }
}
