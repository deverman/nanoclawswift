// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NanoClawAgent",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(
            name: "nanoclaw-agent",
            targets: ["NanoClawAgent"]
        ),
    ],
    dependencies: [
        // SwiftAgents - Pinned to exact version for stability
        .package(url: "https://github.com/christopherkarani/SwiftAgents.git", exact: "0.3.1"),
        
        // CLI argument parsing
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "NanoClawAgent",
            dependencies: [
                .product(name: "SwiftAgents", package: "SwiftAgents"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "NanoClawAgentTests",
            dependencies: [
                "NanoClawAgent",
                .product(name: "SwiftAgents", package: "SwiftAgents"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
    ]
)
