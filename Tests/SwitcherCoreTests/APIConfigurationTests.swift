import XCTest
@testable import SwitcherCore

final class APIConfigurationTests: FixtureTest {
    private func meta(_ id: String, duplicates: Bool = false) throws -> Data {
        let entry: [String: Any] = ["id": id, "name": "fixture name"]
        return try CLIJSON.encode(["appliedId": id, "entries": duplicates ? [entry, entry] : [entry]])
    }
    func testKnownToolsRequireAppliedEntryAndGatewayProfile() throws {
        let profile = try CLIJSON.encode(["inferenceProvider": "gateway", "inferenceGatewayApiKey": "fixture-secret"])
        for (id, expected) in [(APIConfigurationInspector.magpieID, APIConfigurationStatus.magpie),
                               (APIConfigurationInspector.ccSwitchID, .ccSwitch)] {
            XCTAssertEqual(APIConfigurationInspector.classify(scope: .api, meta: try meta(id), profiles: [id: profile]), expected)
        }
    }
    func testInstalledToolOrStaleProfileDoesNotProveAppliedSource() throws {
        let id = APIConfigurationInspector.magpieID, profile = try CLIJSON.encode(["inferenceProvider": "gateway"])
        XCTAssertEqual(APIConfigurationInspector.classify(scope: .api, meta: nil, profiles: [id: profile]), .unknownAPI)
        XCTAssertEqual(APIConfigurationInspector.classify(scope: .subscription, meta: try meta(id), profiles: [id: profile]), .subscription)
        XCTAssertEqual(APIConfigurationInspector.classify(scope: .unknown, meta: try meta(id), profiles: [id: profile]), .unconfirmed)
    }
    func testAmbiguousOrUnsupportedMarkersStayUnknown() throws {
        let id = APIConfigurationInspector.magpieID
        XCTAssertEqual(APIConfigurationInspector.classify(scope: .api, meta: try meta(id, duplicates: true), profiles: [:]), .conflict)
        XCTAssertEqual(APIConfigurationInspector.classify(scope: .api, meta: Data("bad".utf8), profiles: [:]), .unconfirmed)
        XCTAssertEqual(APIConfigurationInspector.classify(scope: .api, meta: try meta(id), profiles: [id: try CLIJSON.encode(["inferenceProvider": "other"])]), .unknownAPI)
        XCTAssertEqual(APIConfigurationInspector.classify(scope: .api, meta: try meta("../../../outside"), profiles: [:]), .unknownAPI)
    }
    func testReaderOnlyUsesKnownProfilePathsAndNeverChangesConfig() throws {
        let library = try directory("Claude-3p/configLibrary"), id = APIConfigurationInspector.ccSwitchID
        let metadata = try meta(id), profile = try CLIJSON.encode(["inferenceProvider": "gateway"])
        try metadata.write(to: library.appendingPathComponent("_meta.json")); try profile.write(to: library.appendingPathComponent(id + ".json"))
        XCTAssertEqual(APIConfigurationInspector.read(support: folder, scope: .api), .ccSwitch)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("_meta.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent(id + ".json")), profile)
        XCTAssertEqual(APIConfigurationStatus.magpie.managerBundleID, "com.yetone.magpie")
        XCTAssertEqual(APIConfigurationStatus.ccSwitch.managerBundleID, "com.ccswitch.desktop")
        XCTAssertNil(APIConfigurationStatus.unknownAPI.managerBundleID)
    }
}
