import Foundation
import CryptoKit
import SwitcherCore

/// Verification only: mounts read-only, never launches code or replaces an app.
enum UpdatePackageVerifier {
    static func sha256(_ url: URL) throws -> String {
        let file=try FileHandle(forReadingFrom:url);defer {try? file.close()}
        var hasher=SHA256()
        while let chunk=try file.read(upToCount:1_048_576),!chunk.isEmpty {hasher.update(data:chunk)}
        return hasher.finalize().map {String(format:"%02x",$0)}.joined()
    }
    static func validateInfo(_ info:[String:Any],release:AppRelease,currentBuild:String) throws {
        guard info["CFBundleIdentifier"] as? String==AppReleasePolicy.bundleID,
              let short=info["CFBundleShortVersionString"] as? String,
              let numeric=AppVersion(short),numeric.prerelease.isEmpty,
              let actual=AppVersion(info["CSReleaseVersion"] as? String ?? short),actual==AppVersion(release.version),numeric.numbers==actual.numbers,
              let build=info["CFBundleVersion"] as? String,!build.isEmpty,
              build.split(separator:".",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && Int($0) != nil}),
              build.allSatisfy({$0.isASCII && ($0.isNumber || $0==".")}),
              build.compare(currentBuild,options:.numeric) == .orderedDescending,
              !info.keys.contains(where:{$0.hasPrefix("CSPreview")}) else {throw SafetyError("安装包身份、版本或构建号不符，未打开。")}
        if !release.prerelease {
            guard (info["CSReleaseChannel"] as? String).map({!["preview","rc","prerelease"].contains($0.lowercased())}) ?? true else {throw SafetyError("预览包不能作为正式更新。")}
        }
        if let minimum=info["LSMinimumSystemVersion"] as? String {
            let os=ProcessInfo.processInfo.operatingSystemVersion
            let current="\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard minimum.compare(current,options:.numeric) != .orderedDescending else {throw SafetyError("此更新需要较新的 macOS。")}
        }
    }
    static func verify(_ file:URL,release:AppRelease,checksum:String,currentBuild:String) async throws {
        try await Task.detached(priority:.utility) {
            guard let expected=AppReleasePolicy.hash(checksum),try sha256(file)==expected else {throw SafetyError("更新包校验失败，未打开。")}
        }.value
        let env=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":FileManager.default.homeDirectoryForCurrentUser.path]
        func command(_ path:String,_ args:[String]) async throws -> String {
            let r=try await BoundedCLICommand.run(home:FileManager.default.homeDirectoryForCurrentUser,executable:URL(fileURLWithPath:path),arguments:args,inherited:env,timeoutSeconds:45,graceSeconds:2)
            guard !r.timedOut,r.status==0 else {throw SafetyError("安装包系统验证未完成，未打开。")}
            return r.text
        }
        func signature(_ path:URL,runtime:Bool) async throws {
            _ = try await command("/usr/bin/codesign",["--verify","--deep","--strict",path.path])
            let text=try await command("/usr/bin/codesign",["--display","--verbose=4",path.path])
            guard text.contains("Authority=Developer ID Application:"),text.contains("TeamIdentifier="+UpdateSigningIdentity.team),
                  !runtime || text.contains("runtime)") && text.contains("Timestamp=") else {throw SafetyError("更新包签名来源不符，未打开。")}
        }
        try await signature(file,runtime:false)
        let assessment=try await command("/usr/sbin/spctl",["--assess","--type","open","--context","context:primary-signature","--verbose=4",file.path])
        guard assessment.contains("source=Notarized Developer ID") else {throw SafetyError("更新包尚未通过公证验证。")}
        let mount=FileManager.default.temporaryDirectory.appendingPathComponent("switcher-update-mount-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:mount,withIntermediateDirectories:true)
        _ = try await command("/usr/bin/hdiutil",["attach","-readonly","-nobrowse","-noautoopen","-mountpoint",mount.path,file.path])
        do {
            let apps=try FileManager.default.contentsOfDirectory(at:mount,includingPropertiesForKeys:[.isSymbolicLinkKey]).filter {$0.pathExtension=="app"}
            guard apps.count==1,let app=apps.first,try app.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else {throw SafetyError("安装包内的应用布局无法确认。")}
            let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:app.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any] ?? [:]
            try validateInfo(info,release:release,currentBuild:currentBuild)
            try await signature(app,runtime:false)
            #if arch(arm64)
            let architecture="arm64"
            #else
            let architecture="x86_64"
            #endif
            for relative in ["Contents/MacOS/ClaudeSwitcher","Contents/Helpers/ClaudeGuard","Contents/Helpers/ClaudeSessionTransfer"] {
                let binary=app.appendingPathComponent(relative)
                try await signature(binary,runtime:true)
                let architectures=try await command("/usr/bin/lipo",["-archs",binary.path])
                guard architectures.split(whereSeparator: \.isWhitespace).contains(Substring(architecture)) else {throw SafetyError("更新包不适用于此 Mac 的处理器。")}
            }
            let appAssessment=try await command("/usr/sbin/spctl",["--assess","--type","execute","--verbose=4",app.path])
            guard appAssessment.contains("source=Notarized Developer ID") else {throw SafetyError("应用尚未通过公证验证。")}
        } catch {
            // Do not recursively delete a mountpoint or force unmount a volume.
            _ = try? await command("/usr/bin/hdiutil",["detach",mount.path])
            throw error
        }
        _ = try await command("/usr/bin/hdiutil",["detach",mount.path])
        try? FileManager.default.removeItem(at:mount)
    }
}
