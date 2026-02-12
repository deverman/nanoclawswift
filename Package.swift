// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NanoClawAgent",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "CronEngineKit",
            targets: ["CronEngineKit"]
        ),
        .executable(
            name: "nanoclaw-agent",
            targets: ["NanoClawAgent"]
        ),
        .executable(
            name: "nanoclaw-host",
            targets: ["NanoClawHost"]
        ),
        .executable(
            name: "session-summary",
            targets: ["SessionSummaryCLI"]
        ),
    ],
    dependencies: [
        // SwiftAgents - Pinned to exact version for stability
        .package(url: "https://github.com/christopherkarani/Swarm.git", exact: "0.3.1"),
        
        // CLI argument parsing
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),

        // Structured logging (latest)
        .package(url: "https://github.com/apple/swift-log.git", from: "1.9.1"),

        // Configuration (for logging and runtime settings)
        .package(url: "https://github.com/apple/swift-configuration", from: "1.0.2"),

        // Swift-native SQLite toolkit
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),

        // Apple Containerization (target version 0.8.0+)
        .package(url: "https://github.com/apple/containerization.git", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "CronEngineKit",
            exclude: ["README.md"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "CronEngineKitTests",
            dependencies: [
                "CronEngineKit"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "NanoClawAgent",
            dependencies: [
                .product(name: "SwiftAgents", package: "Swarm"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "NanoClawAgentTests",
            dependencies: [
                "NanoClawAgent",
                .product(name: "SwiftAgents", package: "Swarm"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "NanoClawHostTests",
            dependencies: [
                "NanoClawHost",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "NanoClawHost",
            dependencies: [
                "CronEngineKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "SessionSummaryCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
    ]
)
