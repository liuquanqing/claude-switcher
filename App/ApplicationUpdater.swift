import Foundation
import AppKit
import Combine
import SwitcherCore

@MainActor struct UpdateOperations {
    let fetch: (URL) async throws -> Data
    let download: (AppReleaseAsset, URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    let verify: (URL, AppRelease, String, String) async throws -> Void
    let directory: URL
}

@MainActor final class ApplicationUpdater: ObservableObject {
    static let shared=ApplicationUpdater(demo: demoMode)
    enum Phase {case idle, checking, current, available, downloading, ready, failed}
    @Published private(set) var phase:Phase = .idle
    @Published private(set) var release:AppRelease?
    @Published private(set) var progress:Double = 0
    @Published private(set) var message:String?
    @Published private(set) var lastCheckedAt:Date?
    @Published var includePrereleases:Bool = false {
        didSet {
            if !demo {UserDefaults.standard.set(includePrereleases,forKey:"includePreviewUpdates")}
            checkID=nil
            if phase == .downloading {cancelDownload()}
            release=nil;downloadedURL=nil;phase = .idle
        }
    }
    let currentVersion:String
    private let currentBuild:String
    private let demo:Bool
    private let operations:UpdateOperations?
    private var timer:Timer?
    private var transport:UpdateDownloadTransport?
    private var checkID:UUID?
    private var downloadID:UUID?
    private(set) var downloadedURL:URL?
    private let architecture:String
    init(demo:Bool=false,operations:UpdateOperations?=nil,currentVersion:String?=nil,currentBuild:String?=nil,architecture:String?=nil) {
        self.demo=demo;self.operations=operations
        self.currentVersion=currentVersion ?? (demo ? "1.3.6-rc.4" : Bundle.main.object(forInfoDictionaryKey:"CSReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.0.0")
        self.currentBuild=currentBuild ?? Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0"
        #if arch(arm64)
        self.architecture=architecture ?? "arm64"
        #else
        self.architecture=architecture ?? "x86_64"
        #endif
        if !demo {
            includePrereleases=UserDefaults.standard.bool(forKey:"includePreviewUpdates")
            lastCheckedAt=UserDefaults.standard.object(forKey:"lastApplicationUpdateCheck") as? Date
        }
    }
    deinit {timer?.invalidate()}
    func startAutomaticChecks() {
        guard !demo,timer==nil else {return}
        timer=Timer.scheduledTimer(withTimeInterval:86400,repeats:true) {[weak self] _ in Task {@MainActor in await self?.check(manual:false)}}
        Task {await check(manual:false)}
    }
    private func fetch(_ url:URL) async throws -> Data {
        if let operations {return try await operations.fetch(url)}
        guard !demo else {throw SafetyError("演示模式不访问更新服务。")}
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=30
        config.urlCache=nil;config.httpCookieStorage=nil
        let session=URLSession(configuration:config,delegate:UpdateRedirectPolicy(),delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        var request=URLRequest(url:url);request.setValue("claude-switcher-updater",forHTTPHeaderField:"User-Agent")
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        let (data,response)=try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode==200,data.count<=2_097_152,
              let final=response.url,AppReleasePolicy.permitsHTTPS(final,redirectedAsset:true) else {throw SafetyError("暂时无法取得更新信息，请稍后重试或前往 GitHub。")}
        return data
    }
    func check(manual:Bool=true) async {
        guard phase != .checking,phase != .downloading else {return}
        if !manual,let lastCheckedAt,Date().timeIntervalSince(lastCheckedAt)<86400 {return}
        let id=UUID();checkID=id
        let previous=phase,channel=includePrereleases
        if demo && operations==nil {message="演示模式不访问更新服务。";phase = .failed;return}
        phase = .checking;message=nil
        // Attempts, including offline/rate-limited ones, are bounded to daily
        // background checks. Explicit user checks remain available.
        lastCheckedAt=Date()
        if !demo {UserDefaults.standard.set(lastCheckedAt,forKey:"lastApplicationUpdateCheck")}
        do {
            let data=try await fetch(AppReleasePolicy.releasesURL)
            let found=try AppReleasePolicy.select(data,current:currentVersion,architecture:architecture,includePrereleases:channel)
            guard checkID==id,channel==includePrereleases else {return}
            release=found;downloadedURL=nil
            if found != nil {phase = .available}
            else {
                let rows=(try? JSONSerialization.jsonObject(with:data)) as? [[String:Any]] ?? []
                let hasNewer=rows.contains {row in
                    guard row["draft"] as? Bool==false,let preview=row["prerelease"] as? Bool,let tag=row["tag_name"] as? String,
                          let version=AppVersion(tag),let current=AppVersion(currentVersion) else {return false}
                    return version>current && (channel || !preview && version.prerelease.isEmpty)
                }
                if hasNewer {throw SafetyError("发现新版，但暂缺可验证的本机安装包，请前往 GitHub。")}
                phase = .current
            }
        } catch {
            guard checkID==id,channel==includePrereleases else {return}
            if manual {message=error.localizedDescription;phase = .failed}
            else {phase=previous;message=nil}
        }
    }
    func download() async {
        guard let release,phase == .available || phase == .failed else {return}
        guard !demo || operations != nil else {message="演示模式不下载或打开安装包。";phase = .failed;return}
        let id=UUID();downloadID=id;phase = .downloading;progress=0;message=nil;downloadedURL=nil
        let parent=operations?.directory ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent(AppReleasePolicy.bundleID+"/Updates")
        let directory=parent.appendingPathComponent(id.uuidString)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            var keepDirectory=false
            defer {if !keepDirectory {try? FileManager.default.removeItem(at:directory)}}
            let checksum:String
            if let digest=release.asset.sha256 {checksum=digest}
            else if let url=release.checksumURL {checksum=try AppReleasePolicy.checksum(try await fetch(url),filename:release.asset.name)}
            else {throw SafetyError("更新包缺少校验信息。")}
            guard downloadID==id else {return}
            let progressHandler:@Sendable(Double)->Void = {[weak self] value in
                Task {@MainActor in guard let self,self.downloadID==id,self.phase == .downloading else {return};self.progress=min(1,max(0,value))}
            }
            let destination=directory.appendingPathComponent(release.asset.name)
            let file:URL
            if let operations {file=try await operations.download(release.asset,destination,progressHandler)}
            else {
                let active=UpdateDownloadTransport(asset:release.asset,destination:destination,progress:progressHandler)
                transport=active;file=try await active.run()
            }
            guard downloadID==id else {return}
            let size=(try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.int64Value
            guard file==destination,size==release.asset.size,try UpdatePackageVerifier.sha256(file)==checksum else {throw SafetyError("更新包校验失败，未打开。")}
            if let operations {try await operations.verify(file,release,checksum,currentBuild)}
            else {try await UpdatePackageVerifier.verify(file,release:release,checksum:checksum,currentBuild:currentBuild)}
            guard downloadID==id else {return}
            downloadedURL=file;keepDirectory=true;progress=1;phase = .ready
        } catch {
            if downloadID==id {phase = .failed;message=error.localizedDescription}
        }
        if downloadID==id {transport=nil;downloadID=nil}
    }
    func cancelDownload() {
        guard phase == .downloading else {return}
        downloadID=nil;transport?.cancel();transport=nil;phase = .available;progress=0;message=nil
    }
    private func availableDownloadedFile() -> URL? {
        guard phase == .ready,let file=downloadedURL else {return nil}
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:file.path,isDirectory:&isDirectory),!isDirectory.boolValue else {
            downloadedURL=nil;phase = .failed;message="更新包尚未完整下载。";return nil
        }
        return file
    }
    func openDownloadedDMG() {
        guard let file=availableDownloadedFile(),!demo else {return}
        if !NSWorkspace.shared.open(file) {NSWorkspace.shared.activateFileViewerSelecting([file])}
    }
    func showDownloadedFile() {
        guard let file=availableDownloadedFile(),!demo else {return}
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
    func openReleasePage() {
        guard !demo else {return}
        NSWorkspace.shared.open(release?.pageURL ?? URL(string:"https://github.com/"+AppReleasePolicy.repository+"/releases")!)
    }
}
