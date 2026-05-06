// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Sanctuary",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SanctuaryCore", targets: ["SanctuaryCore"]),
        .executable(name: "sanctuary", targets: ["SanctuaryCLI"]),
        .executable(name: "sanctuaryd", targets: ["SanctuaryDaemon"]),
        .executable(name: "SanctuaryMenuBar", targets: ["SanctuaryMenuBar"]),
        .executable(name: "sanctuary-cdp-peer-pid-spike", targets: ["CDPPeerPIDSpike"]),
        .executable(name: "sanctuary-ne-filter-spike", targets: ["NEFilterSpike"]),
        .executable(name: "sanctuary-cdpguard-test", targets: ["CDPGuardTestHarness"]),
        .executable(name: "sanctuary-classify-live", targets: ["SanctuaryClassifyLive"])
    ],
    targets: [
        .target(
            name: "SanctuaryCore",
            plugins: ["AgentRegistryPlugin"]
        ),
        .executableTarget(
            name: "SanctuaryCLI",
            dependencies: ["SanctuaryCore"]
        ),
        .executableTarget(
            name: "SanctuaryDaemon",
            dependencies: ["SanctuaryCore"],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "SanctuaryMenuBar",
            dependencies: ["SanctuaryCore"],
            exclude: ["scripts", "README.md"]
        ),
        .executableTarget(name: "CDPPeerPIDSpike"),
        .executableTarget(name: "NEFilterSpike"),
        .executableTarget(
            name: "CDPGuardTestHarness",
            dependencies: ["SanctuaryCore"]
        ),
        .executableTarget(
            name: "SanctuaryClassifyLive",
            dependencies: ["SanctuaryCore"]
        ),
        .executableTarget(name: "AgentRegistryGenerator"),
        .plugin(
            name: "AgentRegistryPlugin",
            capability: .buildTool(),
            dependencies: ["AgentRegistryGenerator"]
        ),
        .testTarget(
            name: "SanctuaryCoreTests",
            dependencies: ["SanctuaryCore", "SanctuaryMenuBar"]
        )
    ]
)
