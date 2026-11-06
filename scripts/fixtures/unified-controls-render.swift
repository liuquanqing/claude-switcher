import AppKit
import SwiftUI
import SwitcherCore

actor FictionalRenderGuard: GuardWorking {
 func registered() -> Bool { false }
 func enable(_ config: SafetyConfig) async throws {
  try await Task.sleep(nanoseconds: 500_000_000)
  throw SafetyError("尚未收到本次守卫检查结果，请重试保护。")
 }
 func disable() { }
}

@main struct InteractionRenders {
 static var outputDirectory: URL {
  var scenario = CommandLine.arguments.contains("--demo-api") ? "api" : "subscription"
  if let source = CommandLine.arguments.first(where: { $0.hasPrefix("--fixture-api-source=") })?.components(separatedBy:"=").last {
   scenario += "-" + source
  }
  if CommandLine.arguments.contains("--fixture-protection-expanded") { scenario += "-expanded" }
  if CommandLine.arguments.contains("--fixture-diagnostic-disagrees") { scenario += "-diagnostic-disagrees" }
  for flag in ["old-usage", "cli-api", "cli-unknown"] {
   if CommandLine.arguments.contains("--fixture-" + flag) { scenario += "-" + flag }
  }
  return URL(fileURLWithPath:"_qa/rc7-ui-revision/visual").appendingPathComponent(scenario)
 }
 @MainActor static func main() {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  Task { @MainActor in
   do { try await renderAll(); exit(0) }
   catch { print(error.localizedDescription); exit(1) }
  }
  NSApp.run()
 }
 @MainActor static func save<V:View>(_ view:V, name:String, width:CGFloat) throws {
  let host=NSHostingView(rootView:view.environment(\.controlActiveState,.active))
  host.appearance=NSAppearance(named:.darkAqua)
  host.frame=NSRect(x:0,y:0,width:width,height:700)
  host.layoutSubtreeIfNeeded()
  let size=host.fittingSize
  host.frame=NSRect(origin:.zero,size:size)
  let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
  window.alphaValue=0;window.contentView=host;window.orderFront(nil)
  host.layoutSubtreeIfNeeded();host.displayIfNeeded()
  guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw SafetyError("No fictional rendering") }
  host.cacheDisplay(in:host.bounds,to:bitmap)
  let dir=outputDirectory
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  try bitmap.representation(using:.png,properties:[:])!.write(to:dir.appendingPathComponent(name+".png"))
  window.orderOut(nil)
  print("\(name) \(size)")
 }
 @MainActor static func saveChoice(_ store: Store, connection: CLIConnectionController, language: String) async throws {
  let host = NSHostingView(rootView: TerminalProtectionCard(store: store, controller: store.protection, busy: false).environment(\.controlActiveState, .active).environment(\.appLanguage, language).padding(12).frame(width:500).background(Color.bg))
  host.appearance = NSAppearance(named: .darkAqua)
  host.frame = NSRect(x:0,y:0,width:500,height:180)
  let window = NSWindow(contentRect:host.frame,styleMask:[.titled],backing:.buffered,defer:false)
  window.alphaValue = 0; window.contentView = host; window.orderFront(nil)
  defer { window.orderOut(nil) }
  try await Task.sleep(nanoseconds: 150_000_000)
  await connection.open()
  try await Task.sleep(nanoseconds: 300_000_000)
  guard let sheet = window.sheets.first, let content = sheet.contentView,
        let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) else {
   print("choice-sheet-" + language + " NOT_RENDERED"); return
  }
  content.layoutSubtreeIfNeeded(); content.cacheDisplay(in:content.bounds,to:bitmap)
  try bitmap.representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent("cli-choice-"+language+".png"))
  print("choice-sheet-"+language+" \(content.bounds.size)")
  if let index = store.profiles.firstIndex(where: { $0.name == store.current }) {
   store.profiles[index].snapshot?.accountID = "another-fictional-account"
  }
  try await Task.sleep(nanoseconds: 350_000_000)
  guard window.sheets.isEmpty else { throw SafetyError("Fictional account changed but the previous choice sheet remained open") }
  print("choice-identity-change-" + language + " PASS")
 }
 @MainActor static func renderAll() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("rc7-update-render-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:root) }
  let payload=Data("fictional package".utf8),fixture=root.appendingPathComponent("fixture")
  try payload.write(to:fixture)
  let hash=try UpdatePackageVerifier.sha256(fixture)
  let base="https://github.com/liuquanqing/claude-switcher/releases/",name="ClaudeSwitcher-1.3.7-arm64.dmg"
  let metadata=try JSONSerialization.data(withJSONObject:[["tag_name":"v1.3.7","draft":false,"prerelease":false,"html_url":base+"tag/v1.3.7","body":"fixture","assets":[["name":name,"size":payload.count,"digest":"sha256:"+hash,"browser_download_url":base+"download/v1.3.7/"+name]]]])
  for language in ["zh","en"] {
   let fullStore = Store(demo:true)
   fullStore.setAppLanguage(language)
   fullStore.cliConnection.contextDidChange()
   if CommandLine.arguments.contains("--fixture-old-usage") {
    fullStore.profiles[0].snapshot?.fetchedAt = Date().addingTimeInterval(-8 * 3600)
    fullStore.profiles[0].usageState = .cached
   }
   if CommandLine.arguments.contains("--fixture-cli-api") {
    fullStore.cliStatus = .otherAuthentication; fullStore.cliEmail = nil; fullStore.cliProfile = nil
    fullStore.cliStandaloneVerified = false
   }
   if CommandLine.arguments.contains("--fixture-cli-unknown") {
    fullStore.cliStatus = .unverified; fullStore.cliStandaloneVerified = false
    fullStore.cliStatusCheckedAt = nil; fullStore.cliStatusDetail = nil
   }
   if CommandLine.arguments.contains("--fixture-diagnostic-disagrees") {
    fullStore.protection.lastDecision = SafetyDecision(.proxyDisconnected)
    fullStore.protection.status = fullStore.protection.lastDecision.message
    await fullStore.protection.checkNow()
   }
   try save(Header(store:fullStore,protection:fullStore.protection,openClaude:{}).environment(\.appLanguage,language).padding(12).frame(width:500).background(Color.bg),name:"header-"+language,width:500)
   try save(Panel(store:fullStore).environment(\.appLanguage,language),name:"full-panel-"+language,width:500)
   var help = TerminalStrip(store:fullStore)
   help.fixtureHelpOnly = true
   try save(help.environment(\.appLanguage,language).background(Color.card),name:"cli-help-"+language,width:340)
   if CommandLine.arguments.contains("--fixture-summary-only") { continue }
   if CommandLine.arguments.contains("--fixture-protection-expanded") {
    try save(TerminalProtectionCard(store:fullStore,controller:fullStore.protection,busy:false).environment(\.appLanguage,language).padding(12).frame(width:500).background(Color.bg),name:"settings-"+language,width:500)
    continue
   }
   let update=ApplicationUpdater(demo:true,operations:.init(fetch:{_ in metadata},download:{_,target,_ in try payload.write(to:target);return target},verify:{_,_,_,_ in},directory:root),currentVersion:"1.3.6-rc.7",currentBuild:"1",architecture:"arm64")
   await update.check()
   var finishInstall:CheckedContinuation<Void,Error>?
   update.installHandler={_,_,_,_ in try await withCheckedThrowingContinuation {finishInstall=$0}}
   try save(ApplicationUpdateView(updater:update,language:language,close:{}),name:"update-available-"+language,width:430)
   await update.download()
   let installTask=Task {@MainActor in await update.installAndRelaunch()}
   while finishInstall == nil {await Task.yield()}
   try save(ApplicationUpdateView(updater:update,language:language,close:{}),name:"update-installing-"+language,width:430)
   finishInstall!.resume(throwing:SafetyError("当前操作尚未完成，请稍后更新。"));await installTask.value
   try save(ApplicationUpdateView(updater:update,language:language,close:{}),name:"update-retry-"+language,width:430)
   let guardStore = Store(demo:true)
   let guardController = ProtectionController(testFiles:SafetyFiles(directory:root.appendingPathComponent("guard-"+language)), worker:FictionalRenderGuard(), observeNetwork:{_ in NetworkObservation(proxyConnected:false,tunOnline:false,country:nil)})
   let startGuard=Task { @MainActor in await guardController.enable() }
   while !guardController.working { await Task.yield() }
   try save(TerminalProtectionCard(store:guardStore,controller:guardController,busy:false).environment(\.appLanguage,language).padding(12).frame(width:500).background(Color.bg),name:"protection-starting-"+language,width:500)
   await startGuard.value
   try save(TerminalProtectionCard(store:guardStore,controller:guardController,busy:false).environment(\.appLanguage,language).padding(12).frame(width:500).background(Color.bg),name:"protection-retry-"+language,width:500)
   for state in ["unlinked","local-default","local-isolated","local-different","default","waiting","different","failed"] {
    let store=Store(demo:true);store.setAppLanguage(language)
    let context: CLIConnectionContext? = store.protection.desktopScope == .subscription
     ? CLIConnectionContext(profile:store.current,identity:store.active!.snapshot!.identity) : nil
    var binding:CLIBinding?
    let connection=CLIConnectionController(operations:.init(context:{context},load:{_ in binding},save:{binding=$0},make:{mode,identity in
     CLIBinding(identity:identity,choice:mode,directory:try CLIBinding.directory(for:mode,identity:identity,home:URL(fileURLWithPath:"/fictional-home")))
    },status:{_ in
     if state == "failed" { throw SafetyError("CLI 状态读取超时或未完成，未修改登录。") }
     return state == "default" ? .matched : state == "different" ? .different : .notLoggedIn
    },launch:{_ in}, localRecord:{_,_ in
     switch state {
     case "local-default", "default": return .sameAccount(.defaultLogin)
     case "local-isolated": return .sameAccount(.isolated)
     case "local-different": return .differentAccount
     case "unlinked", "waiting": return .notPrepared
     default: return .unconfirmed
     }
    }))
    store.cliConnection=connection
    if state == "waiting" { await connection.choose(.isolated) }
    else if state != "unlinked" && !state.hasPrefix("local-") { await connection.open() }
    connection.contextDidChange()
    try save(TerminalProtectionCard(store:store,controller:store.protection,busy:false).environment(\.appLanguage,language).padding(12).frame(width:500).background(Color.bg),name:"cli-"+state+"-"+language,width:500)
    if state == "local-default" {
     try save(TerminalProtectionCard(store:store,controller:store.protection,busy:false).environment(\.appLanguage,language).padding(12).frame(width:420).background(Color.bg),name:"compact-record-"+language,width:420)
    }
    if state == "unlinked", context != nil { try await saveChoice(store, connection: connection, language: language) }
   }
  }
 }
}
