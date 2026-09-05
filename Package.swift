// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GazeEffect",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GazeEffectPipelineCheck", targets: ["GazeEffectPipelineCheck"]),
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
        ),
        .executable(
            name: "GazeEffectOfflineRendererApp",
            targets: ["GazeEffectOfflineRendererApp"]
        )
    ],
    targets: [
        .target(name: "GazeEffectBridge", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "GazeEffectPipelineCheck", dependencies: ["GazeEffectBridge"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "GazeEffectCore"
        ),
        .executableTarget(
            name: "GazeEffectCoreCheck",
            dependencies: ["GazeEffectCore"]
        ),
        .executableTarget(
            name: "GazeEffectPreviewApp",
            dependencies: ["GazeEffectCore", "GazeEffectBridge"],
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
        ),
        .executableTarget(
            name: "GazeEffectOfflineRendererApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
