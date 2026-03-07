import ArgumentParser
import Foundation
import Testing

@testable import NanoClawDevCtl

@Test
func testBuildAgentImageParsingDefaults() throws {
    let command = try NanoClawDevCtl.BuildAgentImage.parse([])
    #expect(command.mode == "slim")
    #expect(command.imageName == "nanoclawswift-agent")
}

@Test
func testBuildAgentImageParsingExplicitModeAndImageName() throws {
    let command = try NanoClawDevCtl.BuildAgentImage.parse([
        "static",
        "--image-name", "custom-agent"
    ])
    #expect(command.mode == "static")
    #expect(command.imageName == "custom-agent")
}

@Test
func testBuildAgentImageRejectsUnsupportedModeBeforeExternalWork() throws {
    var command = try NanoClawDevCtl.BuildAgentImage.parse(["bogus"])
    #expect(throws: ValidationError.self) {
        try command.run()
    }
}

@Test
func testDownloadLinuxBinaryParsingDefaults() throws {
    let command = try NanoClawDevCtl.DownloadLinuxBinary.parse([])
    #expect(command.releaseTag == "nightly")
    #expect(command.repository == "deverman/nanoclawswift")
}

@Test
func testDownloadLinuxBinaryParsingExplicitArgs() throws {
    let command = try NanoClawDevCtl.DownloadLinuxBinary.parse([
        "v1.2.3",
        "--repository", "example/repo"
    ])
    #expect(command.releaseTag == "v1.2.3")
    #expect(command.repository == "example/repo")
}

@Test
func testVerifyTelegramSoakParsingDefaults() throws {
    let command = try NanoClawDevCtl.VerifyTelegramSoak.parse([])
    #expect(command.dbPath.hasSuffix("/.config/clawclaw/store/messages.db"))
    #expect(command.logFile == "/tmp/nanoclaw-host.log")
    #expect(command.chatJid == "telegram_135937217@direct")
    #expect(command.sinceMinutes == 15)
    #expect(command.minEvents == 1)
}

@Test
func testVerifyTelegramSoakParsingExplicitArgs() throws {
    let command = try NanoClawDevCtl.VerifyTelegramSoak.parse([
        "--db-path", "/tmp/messages.db",
        "--log-file", "/tmp/host.log",
        "--chat-jid", "telegram_1@direct",
        "--since-minutes", "30",
        "--min-events", "5"
    ])
    #expect(command.dbPath == "/tmp/messages.db")
    #expect(command.logFile == "/tmp/host.log")
    #expect(command.chatJid == "telegram_1@direct")
    #expect(command.sinceMinutes == 30)
    #expect(command.minEvents == 5)
}

@Test
func testStaticLinuxBuildArgumentsUseProductSdkAndTriple() throws {
    let args = staticLinuxBuildArguments(
        buildPath: ".build/linux/release",
        linuxTargetTriple: "aarch64-swift-linux-musl"
    )
    #expect(args.contains("--product"))
    #expect(args.contains("nanoclaw-agent"))
    #expect(args.contains("--skip-update"))
    #expect(args.contains("--disable-automatic-resolution"))
    #expect(args.contains("--swift-sdk"))
    let sdkIndex = try #require(args.firstIndex(of: "--swift-sdk"))
    #expect(args.count > sdkIndex + 1)
    let sdkValue = args[sdkIndex + 1]
    #expect(
        sdkValue.contains("swift-6.2.4-RELEASE_static-linux-0.1.0")
        || sdkValue.contains("swift-6.2.4-RELEASE_static-linux-0.0.1")
        || sdkValue.contains("swift-6.2.3-RELEASE_static-linux-0.0.1")
    )
    #expect(args.contains("--triple"))
    #expect(args.contains("aarch64-swift-linux-musl"))
    #expect(args.contains("--build-path"))
    #expect(args.contains(".build/linux/release"))
}

@Test
func testPreferredStaticLinuxSDKArgumentUsesEnvironmentOverride() {
    let selected = preferredStaticLinuxSDKArgument(
        linuxTargetTriple: "aarch64-swift-linux-musl",
        environment: ["NANOCLAW_DEVCTL_SWIFT_SDK": "custom-sdk-id"],
        fileExists: { _ in false }
    )
    #expect(selected == "custom-sdk-id")
}

@Test
func testPreferredStaticLinuxSDKArgumentPrefersInstalledArchSpecificBundlePath() {
    let expected = "swift-6.2.4-RELEASE_static-linux-0.1.0"
    let selected = preferredStaticLinuxSDKArgument(
        linuxTargetTriple: "aarch64-swift-linux-musl",
        environment: ["HOME": "/Users/test"],
        fileExists: { path in
            path == "/Users/test/Library/org.swift.swiftpm/swift-sdks/\(expected).artifactbundle/swift-6.2.4-RELEASE_static-linux-0.1.0/swift-linux-musl/musl-1.2.5.sdk/aarch64/usr/lib/swift_static/linux-static/_Concurrency.swiftmodule"
        }
    )
    #expect(selected == expected)
}

@Test
func testPreferredStaticLinuxSDKArgumentFallsBackToLegacy623BundleWhenOnlyLegacyIsInstalled() {
    let expected = "swift-6.2.3-RELEASE_static-linux-0.0.1"
    let selected = preferredStaticLinuxSDKArgument(
        linuxTargetTriple: "aarch64-swift-linux-musl",
        environment: ["HOME": "/Users/test"],
        fileExists: { path in
            path == "/Users/test/Library/org.swift.swiftpm/swift-sdks/\(expected).artifactbundle/swift-6.2.3-RELEASE_static-linux-0.0.1/swift-linux-musl/musl-1.2.5.sdk/aarch64/usr/lib/swift_static/linux-static/_Concurrency.swiftmodule"
        }
    )
    #expect(selected == expected)
}

@Test
func testInferredLinuxMuslTargetTripleMapsKnownArchitectures() {
    #expect(inferredLinuxMuslTargetTriple(machine: "arm64") == "aarch64-swift-linux-musl")
    #expect(inferredLinuxMuslTargetTriple(machine: "aarch64") == "aarch64-swift-linux-musl")
    #expect(inferredLinuxMuslTargetTriple(machine: "x86_64") == "x86_64-swift-linux-musl")
    #expect(inferredLinuxMuslTargetTriple(machine: "amd64") == "x86_64-swift-linux-musl")
}

@Test
func testInferredLinuxMuslTargetTripleRejectsUnknownArchitecture() {
    #expect(inferredLinuxMuslTargetTriple(machine: "riscv64") == nil)
}

@Test
func testResolveLinuxAgentBinaryFindsNestedArtifact() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanoclaw-devctl-test-\(UUID().uuidString)")
    let nested = tempRoot.appendingPathComponent("aarch64-swift-linux-musl/release", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let binary = nested.appendingPathComponent("nanoclaw-agent")
    try Data("x".utf8).write(to: binary)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let resolved = try resolveLinuxAgentBinary(buildPath: tempRoot.path)
    #expect(resolved == binary.path)
}

@Test
func testStaticLinuxBuildPathUsesWarmCacheLocation() {
    let path = staticLinuxBuildPath(repoRoot: "/tmp/repo")
    #expect(path == "/tmp/repo/.build/linux-static-sdk")
}

@Test
func testPreferredSwiftExecutablePathUsesExplicitOverride() {
    let path = preferredSwiftExecutablePath(
        environment: [
            "NANOCLAW_DEVCTL_SWIFT_BIN": "/custom/swift",
            "HOME": "/Users/test"
        ],
        isExecutableFile: { _ in false }
    )
    #expect(path == "/custom/swift")
}

@Test
func testPreferredSwiftExecutablePathUsesPreferredPinnedToolchainWhenPresent() {
    let expected = "/Users/test/Library/Developer/Toolchains/swift-6.2.4-RELEASE.xctoolchain/usr/bin/swift"
    let path = preferredSwiftExecutablePath(
        environment: ["HOME": "/Users/test"],
        isExecutableFile: { candidate in
            candidate == expected
        }
    )
    #expect(path == expected)
}

@Test
func testPreferredSwiftExecutablePathFallsBackToLegacyPinnedToolchain() {
    let expected = "/Users/test/Library/Developer/Toolchains/swift-6.2.3-RELEASE.xctoolchain/usr/bin/swift"
    let path = preferredSwiftExecutablePath(
        environment: ["HOME": "/Users/test"],
        isExecutableFile: { candidate in
            candidate == expected
        }
    )
    #expect(path == expected)
}

@Test
func testPreferredSwiftExecutablePathFallsBackToSwift() {
    let path = preferredSwiftExecutablePath(
        environment: ["HOME": "/Users/test"],
        isExecutableFile: { _ in false }
    )
    #expect(path == "swift")
}

@Test
func testPreferredContainerExecutablePathPrefersSignedInstallerLocation() {
    let path = preferredContainerExecutablePath(
        isExecutableFile: { candidate in
            candidate == "/usr/local/bin/container"
                || candidate == "/opt/homebrew/opt/container/bin/container"
        }
    )
    #expect(path == "/usr/local/bin/container")
}

@Test
func testPreferredContainerExecutablePathFallsBackToBrewLocation() {
    let path = preferredContainerExecutablePath(
        isExecutableFile: { candidate in
            candidate == "/opt/homebrew/opt/container/bin/container"
        }
    )
    #expect(path == "/opt/homebrew/opt/container/bin/container")
}

@Test
func testPreferredContainerExecutablePathFallsBackToEnvLookup() {
    let path = preferredContainerExecutablePath(
        isExecutableFile: { _ in false }
    )
    #expect(path == "container")
}

@Test
func testCompatibleSwiftExecutablePathUses623ToolchainFor623StaticSDK() {
    let path = compatibleSwiftExecutablePath(
        swiftSDKArgument: "swift-6.2.3-RELEASE_static-linux-0.0.1",
        environment: ["HOME": "/Users/test"],
        isExecutableFile: { candidate in
            candidate == "/Users/test/Library/Developer/Toolchains/swift-6.2.4-RELEASE.xctoolchain/usr/bin/swift"
                || candidate == "/Users/test/Library/Developer/Toolchains/swift-6.2.3-RELEASE.xctoolchain/usr/bin/swift"
        }
    )
    #expect(path == "/Users/test/Library/Developer/Toolchains/swift-6.2.3-RELEASE.xctoolchain/usr/bin/swift")
}

@Test
func testCompatibleSwiftExecutablePathReplacesSwiftlyShimFor624StaticSDK() {
    let path = compatibleSwiftExecutablePath(
        swiftSDKArgument: "swift-6.2.4-RELEASE_static-linux-0.1.0",
        environment: [
            "HOME": "/Users/test",
            "NANOCLAW_DEVCTL_SWIFT_BIN": "/var/folders/tmp/swiftly-abc123/bin/swift"
        ],
        isExecutableFile: { candidate in
            candidate == "/var/folders/tmp/swiftly-abc123/bin/swift"
                || candidate == "/Users/test/Library/Developer/Toolchains/swift-6.2.4-RELEASE.xctoolchain/usr/bin/swift"
        }
    )
    #expect(path == "/Users/test/Library/Developer/Toolchains/swift-6.2.4-RELEASE.xctoolchain/usr/bin/swift")
}

@Test
func testRetryClassifierMatchesKnownTransientBuildFailures() {
    #expect(shouldRetryStaticLinuxBuildFailure("Command timed out after 600s: swift build ..."))
    #expect(shouldRetryStaticLinuxBuildFailure("Assertion failed: (db_), function attachDB, file SQLiteBuildDB.cpp, line 125"))
    #expect(shouldRetryStaticLinuxBuildFailure("fatal: cannot change to '/Users/me/Library/org.swift.swiftpm/repositories'"))
}

@Test
func testRetryClassifierSkipsDeterministicCompileFailures() {
    #expect(!shouldRetryStaticLinuxBuildFailure("error: cannot find type 'FooBar' in scope"))
}

@Test
func testCrossArchStaticSDKMismatchClassifierMatchesConcurrencyModuleError() {
    let details = """
    error: could not find module '_Concurrency' for target 'aarch64-swift-linux-musl'; found: x86_64-swift-linux-musl
    """
    #expect(isCrossArchStaticSDKMismatch(details))
}

@Test
func testCrossArchStaticSDKMismatchClassifierMatchesEscapedErrorDescription() {
    let details = """
    commandFailed("error: could not find module \\'_Concurrency\\' for target \\'aarch64-swift-linux-musl\\'; found: x86_64-swift-linux-musl")
    """
    #expect(isCrossArchStaticSDKMismatch(details))
}

@Test
func testCrossArchStaticSDKMismatchClassifierRejectsUnrelatedErrors() {
    #expect(!isCrossArchStaticSDKMismatch("error: cannot find type 'FooBar' in scope"))
}
