// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ClaudeSwitcher", targets: ["ClaudeSwitcher"]),
               .executable(name: "ClaudeGuard", targets: ["ClaudeGuard"]),
               .executable(name: "ClaudeSessionTransfer", targets: ["ClaudeSessionTransfer"])],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(name: "ClaudeSwitcher", dependencies: ["SwitcherCore"], path: "App"),
        .executableTarget(name: "ClaudeGuard", dependencies: ["SwitcherCore"]),
        .executableTarget(name: "ClaudeSessionTransfer", dependencies: ["SwitcherCore"]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"])
    ]
)
