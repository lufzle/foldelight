// swift-tools-version: 5.10
// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let package = Package(
    name: "foldelight",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "foldelight", targets: ["foldelight"])],
    targets: [
        .executableTarget(name: "foldelight", resources: [.copy("Resources/Bend.metal"), .copy("Resources/Fonts"), .copy("Resources/Preview")]),
        .testTarget(name: "foldelightTests", dependencies: ["foldelight"], exclude: ["Fixtures"])
    ]
)
