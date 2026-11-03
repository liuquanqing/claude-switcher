import Foundation
import SwitcherCore

@MainActor func applicationUpdateChecks() async throws -> Int {
    var checks=0
    func require(_ value:Bool,_ detail:String) {precondition(value,detail);checks += 1}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("update-fixture-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let payload=Data("fictional-dmg".utf8),file=root.appendingPathComponent("fixture")
    try payload.write(to:file);let digest=try UpdatePackageVerifier.sha256(file)
    let name="ClaudeSwitcher-1.3.7-arm64.dmg",base="https://github.com/liuquanqing/claude-switcher/releases/"
    let metadata=try CLIJSON.encode(["unused":true])
    _ = metadata
    let rows:[[String:Any]]=[["tag_name":"v1.3.7","prerelease":false,"draft":false,"html_url":base+"tag/v1.3.7","body":"Fictional release","assets":[["name":name,"size":payload.count,"digest":"sha256:"+digest,"browser_download_url":base+"download/v1.3.7/"+name]]]]
    let data=try JSONSerialization.data(withJSONObject:rows)
    var fetched=0,downloads=0,verified=0
    let operations=UpdateOperations(fetch:{_ in fetched += 1;return data},download:{_,target,progress in
        downloads += 1;try payload.write(to:target);progress(1);return target
    },verify:{_,_,_,_ in verified += 1},directory:root.appendingPathComponent("downloads"))
    let updater=ApplicationUpdater(demo:true,operations:operations,currentVersion:"1.3.6-rc.2",currentBuild:"20261102.1.0",architecture:"arm64")
    await updater.check()
    require(updater.phase == .available && updater.release?.version=="1.3.7","the application checks its own public release feed, independently of account refresh")
    await updater.check(manual:false)
    require(fetched==1,"a second daily background check does not re-request metadata")
    await updater.download()
    require(downloads==1 && verified==1 && updater.phase == .ready && updater.downloadedURL != nil,"only a complete hash-matched and verified package reaches the openable state")
    updater.openDownloadedDMG();updater.showDownloadedFile();updater.openReleasePage()
    require(updater.phase == .ready,"fictional updater actions never open applications, Finder or remote pages")
    try FileManager.default.removeItem(at:updater.downloadedURL!)
    updater.openDownloadedDMG()
    require(updater.phase == .failed && updater.downloadedURL==nil,"a deleted installer cannot leave a verified ready action pointing at nothing")
    let release=updater.release!
    let good:[String:Any]=["CFBundleIdentifier":AppReleasePolicy.bundleID,"CFBundleShortVersionString":"1.3.7","CFBundleVersion":"20261103.1.0"]
    try UpdatePackageVerifier.validateInfo(good,release:release,currentBuild:"20261102.1.0");checks += 1
    for key in ["CFBundleIdentifier","CFBundleShortVersionString","CFBundleVersion","CSReleaseChannel","CSPreviewMode"] {
        var bad=good
        bad[key]=key=="CFBundleIdentifier" ? "another.app" : key=="CFBundleShortVersionString" ? "1.3.5" : key=="CFBundleVersion" ? "20261101.0" : key=="CSReleaseChannel" ? "preview" : true
        var rejected=false
        do {try UpdatePackageVerifier.validateInfo(bad,release:release,currentBuild:"20261102.1.0")} catch {rejected=true}
        require(rejected,"wrong bundle/version/build/channel and demo packages are never opened")
    }
    let denied=ApplicationUpdater(demo:true,operations:.init(fetch:{_ in data},download:operations.download,verify:{_,_,_,_ in throw SafetyError("fixture signature rejected")},directory:root.appendingPathComponent("rejected")),currentVersion:"1.3.6",architecture:"arm64")
    await denied.check();await denied.download()
    require(denied.phase == .failed && denied.downloadedURL==nil,"signature failure cannot enable the open-package action")
    let corrupt=ApplicationUpdater(demo:true,operations:.init(fetch:{_ in data},download:{_,target,_ in try Data("wrong".utf8).write(to:target);return target},verify:{_,_,_,_ in preconditionFailure("bad hash cannot reach signature verification")},directory:root.appendingPathComponent("corrupt")),currentVersion:"1.3.6",architecture:"arm64")
    await corrupt.check();await corrupt.download()
    require(corrupt.phase == .failed && corrupt.downloadedURL==nil,"truncated or changed packages are rejected before platform verification")
    var complete:CheckedContinuation<Void,Never>?
    let cancelled=ApplicationUpdater(demo:true,operations:.init(fetch:{_ in data},download:{_,target,_ in
        await withCheckedContinuation {complete=$0};try payload.write(to:target);return target
    },verify:{_,_,_,_ in preconditionFailure("cancelled download cannot be verified or opened")},directory:root.appendingPathComponent("cancelled")),currentVersion:"1.3.6",architecture:"arm64")
    await cancelled.check()
    let task=Task {@MainActor in await cancelled.download()}
    while complete==nil {await Task.yield()}
    cancelled.cancelDownload();complete!.resume();await task.value
    require(cancelled.phase == .available && cancelled.downloadedURL==nil,"a late download completion after cancel cannot resurrect a ready package")
    let silent=ApplicationUpdater(demo:true,operations:.init(fetch:{_ in throw URLError(.notConnectedToInternet)},download:operations.download,verify:operations.verify,directory:root),currentVersion:"1.3.6",architecture:"arm64")
    await silent.check(manual:false)
    require(silent.phase == .idle && silent.message==nil,"background update failures are quiet and never open UI")
    await silent.check()
    require(silent.phase == .failed && silent.message != nil,"explicit checks explain a failure without requesting a GitHub login")

    // Menu presentation uses only fictional release metadata and an injected
    // presenter. It never opens a live window, browser, installer or account.
    var presentations = 0, currentFeedback = 0, failedFeedback = 0, panelDismissals = 0
    let presentation = ApplicationUpdatePresentation { model, language in
        require([.available, .downloading, .ready].contains(model.phase), "the presenter reads the committed phase, not @Published willSet state")
        require(language == "en", "update presentation retains the requested global language")
        presentations += 1
    }
    presentation.onWillPresent = { panelDismissals += 1 }
    func feedback(_ value: ApplicationUpdatePresentation.Feedback) {
        switch value {
        case .current: currentFeedback += 1
        case .failed: failedFeedback += 1
        }
    }
    var menuFetches = 0
    var finishMenuFetch: CheckedContinuation<Data, Error>?
    let menuUpdater = ApplicationUpdater(demo: true, operations: .init(fetch: { _ in
        menuFetches += 1
        return try await withCheckedThrowingContinuation { finishMenuFetch = $0 }
    }, download: operations.download, verify: operations.verify, directory: root),
        currentVersion: "1.3.6", architecture: "arm64")
    presentation.check(updater: menuUpdater, language: "en", feedback: feedback)
    presentation.check(updater: menuUpdater, language: "en", feedback: feedback)
    while finishMenuFetch == nil { await Task.yield() }
    require(presentation.isChecking && presentations == 0 && menuFetches == 1,
            "repeated menu clicks share one check and do not open a checking window")
    finishMenuFetch!.resume(returning: Data("[]".utf8)); finishMenuFetch = nil
    while presentation.isChecking { await Task.yield() }
    require(currentFeedback == 1 && presentations == 0,
            "an up-to-date installation gets lightweight feedback without an update window")

    presentation.check(updater: menuUpdater, language: "en", feedback: feedback)
    while finishMenuFetch == nil { await Task.yield() }
    finishMenuFetch!.resume(throwing: URLError(.notConnectedToInternet)); finishMenuFetch = nil
    while presentation.isChecking { await Task.yield() }
    require(failedFeedback == 1 && presentations == 0 && menuUpdater.phase == .failed,
            "a failed menu check explains the error without opening an empty update page")

    // A user click during the daily check must attach to that in-flight result.
    let background = Task { await menuUpdater.check(manual: true) }
    while finishMenuFetch == nil { await Task.yield() }
    let beforeSharedFetches = menuFetches
    presentation.check(updater: menuUpdater, language: "en", feedback: feedback)
    finishMenuFetch!.resume(returning: data); finishMenuFetch = nil
    await background.value
    while presentation.isChecking { await Task.yield() }
    require(!presentation.isChecking && menuFetches == beforeSharedFetches && presentations == 1,
            "an in-flight check is shared and only an available release opens the update window")

    await menuUpdater.download()
    let beforeReadyFetches = menuFetches
    presentation.check(updater: menuUpdater, language: "en", feedback: feedback)
    require(menuUpdater.phase == .ready && presentations == 2 && menuFetches == beforeReadyFetches,
            "reopening a verified installer preserves it rather than discarding it for a new check")

    presentation.check(updater: silent, language: "en", feedback: feedback)
    while presentation.isChecking { await Task.yield() }
    require(failedFeedback == 2 && presentations == 2,
            "retry after a failed check stays lightweight and never claims current")

    var finishDaily: CheckedContinuation<Data, Error>?
    let daily = ApplicationUpdater(demo: true, operations: .init(fetch: { _ in
        try await withCheckedThrowingContinuation { finishDaily = $0 }
    }, download: operations.download, verify: operations.verify, directory: root),
        currentVersion: "1.3.6", architecture: "arm64")
    let dailyTask = Task { await daily.check(manual: false) }
    while finishDaily == nil { await Task.yield() }
    presentation.check(updater: daily, language: "en", feedback: feedback)
    finishDaily!.resume(throwing: URLError(.notConnectedToInternet)); finishDaily = nil
    await dailyTask.value
    while presentation.isChecking { await Task.yield() }
    require(failedFeedback == 3 && daily.phase == .idle && presentations == 2,
            "an explicit click joining an offline daily check gets failure feedback rather than silence")
    require(panelDismissals == presentations,
            "only actionable update presentations dismiss the menu panel before fronting a normal window")
    return checks
}
