// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NanoClawAgent",
    platforms: [
        .macOS("26.0"),
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
            name: "nanoclaw-hostctl",
            targets: ["NanoClawHostCtl"]
        ),
        .executable(
            name: "session-summary",
            targets: ["SessionSummaryCLI"]
        ),
        .executable(
            name: "nanoclaw-devctl",
            targets: ["NanoClawDevCtl"]
        ),
    ],
    dependencies: [
        // SwiftAgents pinned to fork revision for reproducible dependency resolution.
        .package(url: "https://github.com/deverman/Swarm.git", revision: "def222ee68681667a6d3b7a497180454b064e61e"),

        // CLI argument parsing
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),

        // Structured logging (latest)
        .package(url: "https://github.com/apple/swift-log.git", from: "1.9.1"),

        // Configuration (for logging and runtime settings)
        .package(url: "https://github.com/apple/swift-configuration", from: "1.0.2"),

        // Swift-native SQLite toolkit
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),

        // Telegram Bot API SDK (Swift-native polling/webhook support)
        .package(url: "https://github.com/nerzh/swift-telegram-bot.git", from: "4.3.0"),

        // Official Swift MCP SDK
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.2"),

        // Lightweight, production-grade Swift HTTP server/router
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "NanoClawCommandKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "NanoClawCommandKitTests",
            dependencies: [
                "NanoClawCommandKit"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
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
                "NanoClawCommandKit",
                .product(name: "SwiftAgents", package: "Swarm"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "MCP", package: "swift-sdk"),
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
        .testTarget(
            name: "NanoClawDevCtlTests",
            dependencies: [
                "NanoClawDevCtl",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "NanoClawHostCtlTests",
            dependencies: [
                "NanoClawHostCtl"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "NanoClawHost",
            dependencies: [
                "NanoClawCommandKit",
                "CronEngineKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTelegramBot", package: "swift-telegram-bot"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "NanoClawHostCtl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
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
        .executableTarget(
            name: "NanoClawDevCtl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
    ]
)
