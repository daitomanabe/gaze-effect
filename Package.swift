// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GazeEffect",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GazeEffectCore",
            targets: ["GazeEffectCore"]
        ),
        .executable(
            name: "GazeEffectCoreCheck",
            targets: ["GazeEffectCoreCheck"]
        ),
        .executable(
            name: "GazeEffectPreviewApp",
            targets: ["GazeEffectPreviewApp"]
        ),
        .executable(
            name: "GazeEffectImageTool",
            targets: ["GazeEffectImageTool"]
        )
    ],
    targets: [
        .target(
            name: "GazeEffectCore"
        ),
        .executableTarget(
            name: "GazeEffectCoreCheck",
            dependencies: ["GazeEffectCore"]
        ),
        .executableTarget(
            name: "GazeEffectPreviewApp",
            dependencies: ["GazeEffectCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "GazeEffectImageTool",
            dependencies: ["GazeEffectCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
