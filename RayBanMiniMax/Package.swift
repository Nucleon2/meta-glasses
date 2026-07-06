// swift-tools-version: 5.9
//
// Package.swift
// RayBanMiniMax
//
// Auxiliary Swift Package used to run pure-utility smoke tests without the
// iOS toolchain. The real app target lives in the Xcode project generated
// by `xcodegen` from `project.yml`.
//
// Usage:
//   cd RayBanMiniMax
//   ./scripts/smoketest.sh
//

import PackageDescription

let package = Package(
    name: "RayBanMiniMaxCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RayBanMiniMaxCore", targets: ["RayBanMiniMaxCore"])
    ],
    targets: [
        .target(
            name: "RayBanMiniMaxCore",
            path: "RayBanMiniMax",
            exclude: [
                "App",
                "UI",
                "Resources",
                "Core/AudioPipeline.swift",
                "Core/CameraPipeline.swift",
                "Core/SessionManager.swift",
                "Core/DATBridge.swift",
                "Core/AppSettings.swift",
                "STT"
            ],
            sources: [
                "API",
                "AI",
                "Utils"
            ]
        )
    ]
)
