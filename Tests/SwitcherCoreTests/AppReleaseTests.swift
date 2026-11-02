import XCTest
@testable import SwitcherCore

final class AppReleaseTests:XCTestCase {
    func row(_ version:String,preview:Bool=false,draft:Bool=false,arch:String="arm64") -> [String:Any] {
        let tag="v"+version,name="ClaudeSwitcher-"+version+"-"+arch+".dmg"
        return ["tag_name":tag,"prerelease":preview,"draft":draft,"html_url":"https://github.com/liuquanqing/claude-switcher/releases/tag/"+tag,"body":"Release notes",
            "assets":[["name":name,"size":100,"digest":"sha256:"+String(repeating:"a",count:64),"browser_download_url":"https://github.com/liuquanqing/claude-switcher/releases/download/"+tag+"/"+name]]]
    }
    func select(_ rows:[[String:Any]],_ current:String="1.3.5",_ preview:Bool=false) throws -> AppRelease? {
        try AppReleasePolicy.select(JSONSerialization.data(withJSONObject:rows),current:current,architecture:"arm64",includePrereleases:preview)
    }
    func testPrereleaseOrderingAndPromotion() {
        XCTAssertLessThan(AppVersion("1.3.6-rc.2")!,AppVersion("1.3.6-rc.10")!)
        XCTAssertLessThan(AppVersion("1.3.6-rc.10")!,AppVersion("1.3.6")!)
        XCTAssertEqual(AppVersion("v1.3.6+build.9"),AppVersion("1.3.6+build.10"))
        XCTAssertLessThan(AppVersion("1.9.9")!,AppVersion("1.10.0")!)
        for value in ["1.2","1.2.3-","01.2.3","1.2.3-rc.01","1.2.3-..","1.2.3+","1.2.3+build..2","hello"] {XCTAssertNil(AppVersion(value),value)}
    }
    func testStableAndPreviewChannels() throws {
        XCTAssertEqual(try select([row("1.3.6-rc.2",preview:true),row("1.3.5")]),nil)
        XCTAssertEqual(try select([row("1.3.6-rc.2",preview:true)],"1.3.5",true)?.version,"1.3.6-rc.2")
        XCTAssertEqual(try select([row("1.3.6")],"1.3.6-rc.1")?.version,"1.3.6")
        XCTAssertNil(try select([row("1.3.4"),row("1.3.7",draft:true)]))
        XCTAssertNil(try select([row("1.3.6-rc.2",preview:false)]))
    }
    func testArchitectureOwnerAndIntegrityInformation() throws {
        XCTAssertNil(try select([row("1.3.6",arch:"x86_64")]))
        var bad=row("1.3.6"),assets=bad["assets"] as! [[String:Any]]
        assets[0]["browser_download_url"]="https://github.com/attacker/other/releases/download/v1.3.6/a.dmg";bad["assets"]=assets
        XCTAssertNil(try select([bad]))
        bad=row("1.3.6");assets=bad["assets"] as! [[String:Any]];assets[0].removeValue(forKey:"digest");bad["assets"]=assets
        XCTAssertNil(try select([bad]))
        assets.append(["name":"SHA256SUMS","browser_download_url":"https://github.com/liuquanqing/claude-switcher/releases/download/v1.3.6/SHA256SUMS"]);bad["assets"]=assets
        XCTAssertNotNil(try select([bad])?.checksumURL)
        assets[0]["size"]=true;bad["assets"]=assets;XCTAssertNil(try select([bad]))
    }
    func testChecksumAmbiguityAndRedirectBoundaries() throws {
        let hash=String(repeating:"b",count:64)
        XCTAssertEqual(try AppReleasePolicy.checksum(Data((hash+"  good.dmg\n").utf8),filename:"good.dmg"),hash)
        XCTAssertThrowsError(try AppReleasePolicy.checksum(Data((hash+"  other.dmg\n").utf8),filename:"good.dmg"))
        XCTAssertThrowsError(try AppReleasePolicy.checksum(Data((hash+"  good.dmg\n"+hash+"  good.dmg\n").utf8),filename:"good.dmg"))
        for raw in ["http://github.com/a","https://github.com.evil.invalid/a","https://127.0.0.1/a","https://user@github.com/a","https://github.com:8443/a"] {
            XCTAssertFalse(AppReleasePolicy.permitsHTTPS(URL(string:raw)!,redirectedAsset:true))
        }
        XCTAssertTrue(AppReleasePolicy.permitsHTTPS(URL(string:"https://release-assets.githubusercontent.com/a")!,redirectedAsset:true))
        XCTAssertFalse(AppReleasePolicy.permitsHTTPS(URL(string:"https://release-assets.githubusercontent.com/a")!))
    }
}
