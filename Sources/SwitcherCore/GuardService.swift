import Foundation

public struct GuardService {
    public static let label = "dev.claudeswitcher.guard"
    public let files: SafetyFiles
    public let helper: URL
    public let launchAgents: URL
    public let legacyPlist: URL
    private let command: (String, [String]) throws -> (Int32, String)
    public var plistURL: URL { launchAgents.appendingPathComponent(Self.label + ".plist") }
    private var domain: String { "gui/\(getuid())" }
    public init(files: SafetyFiles, helper: URL,
                launchAgents: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
                legacyPlist: URL = URL(fileURLWithPath: "/Library/LaunchDaemons/local.claude-bodyguard.plist"),
                command: @escaping (String, [String]) throws -> (Int32, String) = LocalCommand.run) {
        self.files = files; self.helper = helper; self.launchAgents = launchAgents
        self.legacyPlist = legacyPlist; self.command = command
    }
    public var registered: Bool {
        (try? command("/bin/launchctl", ["print", domain + "/" + Self.label]).0) == 0
    }
    public func enable(_ requested: SafetyConfig) throws {
        guard !FileManager.default.fileExists(atPath: legacyPlist.path) else {
            throw SafetyError("检测到旧版保镖，请先按迁移文档停用旧服务，避免两套守卫同时运行。")
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SafetyError("守卫组件缺失，请重新安装完整 App。")
        }
        var config = try requested.validated(); config.enabled = true
        try files.save(config, to: files.configURL)
        let plist: [String: Any] = ["Label": Self.label, "ProgramArguments": [helper.path, "--config", files.configURL.path],
                                    "StartInterval": Int(SafetyConfig.interval), "RunAtLoad": true]
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        if registered {
            guard try command("/bin/launchctl", ["bootout", domain + "/" + Self.label]).0 == 0 else {
                throw SafetyError("旧守卫实例未能退出，配置已保存但服务未更新。")
            }
        }
        guard try command("/bin/launchctl", ["bootstrap", domain, plistURL.path]).0 == 0 else {
            throw SafetyError("配置已保存，但独立守卫注册失败；启动仍会被拦截。")
        }
    }
    public func disable() throws {
        var config = (try? files.loadConfig()) ?? SafetyConfig()
        config.enabled = false
        // Persist before unloading so an in-flight invocation will not be enabled next time.
        try files.save(config, to: files.configURL)
        if registered {
            guard try command("/bin/launchctl", ["bootout", domain + "/" + Self.label]).0 == 0 else {
                throw SafetyError("保护已设为关闭，但后台任务未能卸载，请重试。")
            }
        }
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
    }
}
