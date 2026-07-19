// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "YouTubeRealFullscreen",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(
            name: "YouTubeRealFullscreenBridge",
            targets: ["YouTubeRealFullscreenBridge"]
        ),
    ],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(
            name: "YouTubeRealFullscreenBridge",
            dependencies: ["BridgeCore"]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
