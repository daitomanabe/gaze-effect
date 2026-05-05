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
        )
    ],
    targets: [
        .target(
            name: "GazeEffectCore"
        ),
        .executableTarget(
            name: "GazeEffectCoreCheck",
            dependencies: ["GazeEffectCore"]
        )
    ]
)
