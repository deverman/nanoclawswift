import ArgumentParser
import Foundation
import Darwin

@main
struct NanoClawDevCtl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nanoclaw-devctl",
        abstract: "Swift-native developer utilities for NanoClawSwift.",
        subcommands: [
            BuildAgentImage.self,
            RebuildAndRestart.self,
            DownloadLinuxBinary.self,
            VerifyTelegramSoak.self
        ]
    )
}

private enum DevCtlError: Error, LocalizedError {
    case commandFailed(String)
    case invalidResponse(String)
    case fileNotFound(String)
    case lockUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message),
             .invalidResponse(let message),
             .fileNotFound(let message),
             .lockUnavailable(let message):
            return message
        }
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private enum DevRuntime {
    static var buildTimeoutSeconds: TimeInterval {
        readTimeoutEnv(name: "NANOCLAW_DEVCTL_BUILD_TIMEOUT_SEC", defaultValue: 10 * 60)
    }

    static var containerBuildTimeoutSeconds: TimeInterval {
        readTimeoutEnv(name: "NANOCLAW_DEVCTL_CONTAINER_BUILD_TIMEOUT_SEC", defaultValue: 10 * 60)
    }

    static var repoRoot: String {
        FileManager.default.currentDirectoryPath
    }

    private static var lockFilePath: String {
        "\(repoRoot)/.build/.nanoclaw-devctl.lock"
    }

    static var preferredContainerCLI: String {
        let brewPath = "/opt/homebrew/opt/container/bin/container"
        if FileManager.default.isExecutableFile(atPath: brewPath) {
            return brewPath
        }
        return "container"
    }

    static var preferredSwiftCLI: String {
        preferredSwiftExecutablePath()
    }

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        if let environment {
            process.environment = environment
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if let timeout {
            let start = Date()
            while process.isRunning {
                if Date().timeIntervalSince(start) > timeout {
                    process.terminate()
                    let graceDeadline = Date().addingTimeInterval(3.0)
                    while process.isRunning && Date() < graceDeadline {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    throw DevCtlError.commandFailed(
                        "Command timed out after \(Int(timeout))s: \(executable) \(arguments.joined(separator: " "))\n\(out)\(err)"
                    )
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        } else {
            process.waitUntilExit()
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    static func requireSuccess(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessResult {
        let result = try run(executable, arguments, cwd: cwd, environment: environment, timeout: timeout)
        if result.status != 0 {
            let combinedOutput = [result.stdout, result.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw DevCtlError.commandFailed(
                "Command failed: \(executable) \(arguments.joined(separator: " "))\n\(combinedOutput)"
            )
        }
        if !result.stdout.isEmpty { print(result.stdout, terminator: "") }
        if !result.stderr.isEmpty { fputs(result.stderr, stderr) }
        return result
    }

    static func withRepositoryLock<T>(_ body: () throws -> T) throws -> T {
        let lockPath = lockFilePath
        let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            throw DevCtlError.lockUnavailable("Unable to open devctl lock file at \(lockPath)")
        }
        defer { close(lockFD) }

        if flock(lockFD, LOCK_EX) != 0 {
            throw DevCtlError.lockUnavailable("Unable to acquire devctl lock at \(lockPath)")
        }
        defer { flock(lockFD, LOCK_UN) }

        return try body()
    }

    static func withTemporaryDirectory<T>(prefix: String, _ body: (String) throws -> T) throws -> T {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        return try body(tempRoot.path)
    }

    private static func readTimeoutEnv(name: String, defaultValue: TimeInterval) -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let parsed = TimeInterval(raw),
              parsed >= 30
        else {
            return defaultValue
        }
        return parsed
    }
}

private func defaultStateRootPath() -> String {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config")
        .appendingPathComponent("clawclaw")
        .path
}

extension NanoClawDevCtl {
    struct BuildAgentImage: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "build-agent-image",
            abstract: "Build the Linux agent binary and package the agent container image."
        )

        @Argument(help: "Build mode: slim or static.")
        var mode: String = "slim"

        @Option(name: .long, help: "Container image name.")
        var imageName: String = "nanoclawswift-agent"

        mutating func run() throws {
            try DevRuntime.withRepositoryLock {
                try runBuildAgentImage(mode: mode, imageName: imageName)
            }
        }
    }

    struct RebuildAndRestart: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rebuild-and-restart",
            abstract: "Serialize agent image rebuild and host restart in one command."
        )

        @Argument(help: "Build mode: slim or static.")
        var mode: String = "slim"

        @Option(name: .long, help: "Container image name.")
        var imageName: String = "nanoclawswift-agent"

        @Flag(name: .long, help: "Run host in foreground after restart.")
        var foreground: Bool = false

        mutating func run() throws {
            try DevRuntime.withRepositoryLock {
                try runBuildAgentImage(mode: mode, imageName: imageName)

                var restartArgs = ["run", "nanoclaw-hostctl", "restart"]
                if foreground {
                    restartArgs.append("--foreground")
                }
                print("\nStep 3: Restarting host...")
                _ = try DevRuntime.requireSuccess(DevRuntime.preferredSwiftCLI, restartArgs, cwd: DevRuntime.repoRoot)
                print("\nRebuild + restart complete.")
            }
        }
    }

    struct DownloadLinuxBinary: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download-linux-binary",
            abstract: "Download prebuilt Linux nanoclaw-agent binary from GitHub releases."
        )

        @Argument(help: "Release tag (default: nightly/latest release).")
        var releaseTag: String = "nightly"

        @Option(name: .long, help: "GitHub repo in owner/name format.")
        var repository: String = "deverman/nanoclawswift"

        mutating func run() throws {
            print("=== Downloading NanoClawSwift Linux Binary ===")
            print("Repository: \(repository)")
            print("Release: \(releaseTag)\n")

            let binaryDir = "\(DevRuntime.repoRoot)/.build/linux-glibc/release"
            let binaryPath = "\(binaryDir)/nanoclaw-agent"
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: binaryDir),
                withIntermediateDirectories: true
            )

            let downloadURLString: String
            if releaseTag == "nightly" {
                downloadURLString = try latestBinaryURL(repository: repository)
            } else {
                downloadURLString = "https://github.com/\(repository)/releases/download/\(releaseTag)/nanoclaw-agent"
            }

            guard let downloadURL = URL(string: downloadURLString) else {
                throw DevCtlError.invalidResponse("Invalid download URL: \(downloadURLString)")
            }

            print("Downloading from:\n  \(downloadURL.absoluteString)\n")
            let data = try Data(contentsOf: downloadURL)
            try data.write(to: URL(fileURLWithPath: binaryPath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: binaryPath
            )

            print("Binary downloaded: \(binaryPath)\n")
            _ = try DevRuntime.requireSuccess("file", [binaryPath], cwd: DevRuntime.repoRoot)
            print("\nNext step:")
            print("  swift run nanoclaw-devctl build-agent-image slim")
        }

        private func latestBinaryURL(repository: String) throws -> String {
            let releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases")!
            let data = try Data(contentsOf: releasesURL)
            guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw DevCtlError.invalidResponse("Unable to parse GitHub releases response.")
            }

            for release in releases {
                guard let assets = release["assets"] as? [[String: Any]] else { continue }
                for asset in assets {
                    guard let name = asset["name"] as? String,
                          name == "nanoclaw-agent",
                          let url = asset["browser_download_url"] as? String
                    else {
                        continue
                    }
                    return url
                }
            }

            throw DevCtlError.invalidResponse(
                "Could not find release asset named 'nanoclaw-agent' in \(repository)."
            )
        }
    }

    struct VerifyTelegramSoak: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify-telegram-soak",
            abstract: "Verify recent Telegram command handling via SQLite + host log invariants."
        )

        @Option(name: .long, help: "Path to host SQLite DB.")
        var dbPath: String = "\(defaultStateRootPath())/store/messages.db"

        @Option(name: .long, help: "Path to host runtime log file.")
        var logFile: String = "/tmp/nanoclaw-host.log"

        @Option(name: .long, help: "Telegram chat JID to verify.")
        var chatJid: String = "telegram_135937217@direct"

        @Option(name: .long, help: "Time window in minutes.")
        var sinceMinutes: Int = 15

        @Option(name: .long, help: "Minimum inbound events required in the window.")
        var minEvents: Int = 1

        mutating func run() throws {
            guard sinceMinutes > 0 else {
                throw ValidationError("--since-minutes must be > 0")
            }
            guard minEvents >= 0 else {
                throw ValidationError("--min-events must be >= 0")
            }
            guard FileManager.default.fileExists(atPath: dbPath) else {
                throw DevCtlError.fileNotFound("DB not found: \(dbPath)")
            }
            guard FileManager.default.fileExists(atPath: logFile) else {
                throw DevCtlError.fileNotFound("Log file not found: \(logFile)")
            }

            let since = Date().addingTimeInterval(TimeInterval(-sinceMinutes * 60))
            let sinceISO = ISO8601DateFormatter().string(from: since)
            let escapedJid = chatJid.replacingOccurrences(of: "'", with: "''")

            let inboundCount = try sqliteSingleInt(
                dbPath: dbPath,
                sql: "SELECT COUNT(*) FROM inbound_events WHERE channel='telegram' AND chat_jid='\(escapedJid)' AND received_at >= '\(sinceISO)';"
            )
            let outboundAckedCount = try sqliteSingleInt(
                dbPath: dbPath,
                sql: "SELECT COUNT(*) FROM outbound_messages WHERE channel='telegram' AND chat_jid='\(escapedJid)' AND status='acked' AND created_at >= '\(sinceISO)';"
            )

            let logText = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
            let acceptedRequests = acceptedRequestIDs(logText: logText, chatJid: chatJid, since: since)
            let completedSuccess = completedSuccessRequestIDs(logText: logText, since: since)
            let matchedSuccess = acceptedRequests.filter { completedSuccess.contains($0) }

            print("Telegram soak verification")
            print("chat_jid: \(chatJid)")
            print("window: last \(sinceMinutes)m since \(sinceISO)")
            print("db.inbound_events: \(inboundCount)")
            print("db.outbound_messages(acked): \(outboundAckedCount)")
            print("log.accepted_requests: \(acceptedRequests.count)")
            print("log.completed_success: \(matchedSuccess.count)")

            if inboundCount < minEvents {
                throw DevCtlError.invalidResponse(
                    "Soak check failed: inbound events \(inboundCount) < required \(minEvents)"
                )
            }
            if matchedSuccess.count < acceptedRequests.count {
                throw DevCtlError.invalidResponse(
                    "Soak check failed: only \(matchedSuccess.count)/\(acceptedRequests.count) accepted requests completed successfully"
                )
            }
            if outboundAckedCount < max(minEvents, acceptedRequests.count) {
                throw DevCtlError.invalidResponse(
                    "Soak check failed: acked outbound \(outboundAckedCount) < expected \(max(minEvents, acceptedRequests.count))"
                )
            }

            print("Soak check passed.")
        }

        private func sqliteSingleInt(dbPath: String, sql: String) throws -> Int {
            let result = try DevRuntime.requireSuccess("sqlite3", [dbPath, sql])
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed) ?? 0
        }

        private func acceptedRequestIDs(logText: String, chatJid: String, since: Date) -> [String] {
            var ids: [String] = []
            for line in logText.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.contains("Accepted inbound event telegram \(chatJid) request="),
                      let timestamp = extractTimestamp(from: String(line)),
                      timestamp >= since,
                      let requestID = extractRequestID(from: String(line))
                else {
                    continue
                }
                ids.append(requestID)
            }
            return ids
        }

        private func completedSuccessRequestIDs(logText: String, since: Date) -> Set<String> {
            var ids = Set<String>()
            for line in logText.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.contains("Completed queue job request="),
                      line.contains("status=success"),
                      let timestamp = extractTimestamp(from: String(line)),
                      timestamp >= since,
                      let requestID = extractRequestID(from: String(line))
                else {
                    continue
                }
                ids.insert(requestID)
            }
            return ids
        }

        private func extractTimestamp(from line: String) -> Date? {
            // Example prefix: 2026-02-15T19:58:06+0800
            guard let token = line.split(separator: " ").first else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            return formatter.date(from: String(token))
        }

        private func extractRequestID(from line: String) -> String? {
            guard let range = line.range(of: "request=") else { return nil }
            let tail = line[range.upperBound...]
            let request = tail.split(separator: " ").first.map(String.init) ?? ""
            return request.isEmpty ? nil : request
        }
    }
}

private func runBuildAgentImage(mode: String, imageName: String) throws {
    let normalizedMode = mode.lowercased()
    guard normalizedMode == "slim" || normalizedMode == "static" else {
        throw ValidationError("Unsupported mode '\(mode)'. Use slim or static.")
    }

    let repoRoot = DevRuntime.repoRoot
    let tag = "\(imageName):\(normalizedMode)"
    let containerCLI = DevRuntime.preferredContainerCLI

    print("Building NanoClawSwift agent container image...")
    print("Mode: \(normalizedMode)")
    print("Tag:  \(tag)\n")

    if normalizedMode == "slim" {
        print("Step 1: Building Linux executable via Swift static SDK...")
        let staticBuildPath = staticLinuxBuildPath(repoRoot: repoRoot)
        let outputPath = "\(repoRoot)/.build/linux-output-nanoclaw-agent"

        do {
            let staticBuildOutput = try runStaticLinuxBuild(
                repoRoot: repoRoot,
                buildPath: staticBuildPath,
                timeout: DevRuntime.buildTimeoutSeconds
            )
            // Dockerfile.slim expects this fixed host path.
            _ = try DevRuntime.requireSuccess("cp", [staticBuildOutput, outputPath], cwd: repoRoot)
        } catch {
            let details = String(describing: error)
            if isCrossArchStaticSDKMismatch(details) {
                print("Detected cross-arch static SDK module mismatch; retrying in isolated build path...")
                let isolatedPath = "\(FileManager.default.temporaryDirectory.path)/nanoclaw-linux-static-sdk-\(UUID().uuidString)"
                let staticBuildOutput = try runStaticLinuxBuild(
                    repoRoot: repoRoot,
                    buildPath: isolatedPath,
                    timeout: max(DevRuntime.buildTimeoutSeconds, 20 * 60)
                )
                _ = try DevRuntime.requireSuccess("cp", [staticBuildOutput, outputPath], cwd: repoRoot)
                try? FileManager.default.removeItem(atPath: isolatedPath)
                guard FileManager.default.fileExists(atPath: outputPath) else {
                    throw DevCtlError.fileNotFound("Build artifact missing at \(outputPath)")
                }
                _ = try DevRuntime.requireSuccess("file", [outputPath], cwd: repoRoot)
                print("\nStep 2: Packaging image with container/Dockerfile.slim...")
                _ = try DevRuntime.requireSuccess(
                    containerCLI,
                    [
                        "build",
                        "-f", "\(repoRoot)/container/Dockerfile.slim",
                        "-t", tag,
                        "."
                    ],
                    cwd: repoRoot,
                    timeout: DevRuntime.containerBuildTimeoutSeconds
                )
                print("\nBuild complete: \(tag)")
                return
            }
            guard shouldRetryStaticLinuxBuildFailure(details) else {
                throw error
            }
            print("Static Linux build failed with a transient error; cleaning build path and retrying once...")
            try? FileManager.default.removeItem(atPath: staticBuildPath)
            let staticBuildOutput = try runStaticLinuxBuild(
                repoRoot: repoRoot,
                buildPath: staticBuildPath,
                timeout: max(DevRuntime.buildTimeoutSeconds, 20 * 60)
            )
            // Dockerfile.slim expects this fixed host path.
            _ = try DevRuntime.requireSuccess("cp", [staticBuildOutput, outputPath], cwd: repoRoot)
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw DevCtlError.fileNotFound("Build artifact missing at \(outputPath)")
        }

        _ = try DevRuntime.requireSuccess("file", [outputPath], cwd: repoRoot)
        print("\nStep 2: Packaging image with container/Dockerfile.slim...")
        _ = try DevRuntime.requireSuccess(
            containerCLI,
            [
                "build",
                "-f", "\(repoRoot)/container/Dockerfile.slim",
                "-t", tag,
                "."
            ],
            cwd: repoRoot,
            timeout: DevRuntime.containerBuildTimeoutSeconds
        )
    } else {
        throw DevCtlError.commandFailed("Static mode is not yet migrated. Use slim mode.")
    }

    print("\nBuild complete: \(tag)")
}

func staticLinuxBuildPath(repoRoot: String) -> String {
    "\(repoRoot)/.build/linux-static-sdk"
}

func preferredSwiftExecutablePath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
) -> String {
    if let override = environment["NANOCLAW_DEVCTL_SWIFT_BIN"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
        return override
    }

    let home = environment["HOME"] ?? NSHomeDirectory()
    let pinnedToolchainSwift = "\(home)/Library/Developer/Toolchains/swift-6.2.3-RELEASE.xctoolchain/usr/bin/swift"
    if isExecutableFile(pinnedToolchainSwift) {
        return pinnedToolchainSwift
    }

    return "swift"
}

func shouldRetryStaticLinuxBuildFailure(_ details: String) -> Bool {
    let normalized = details.lowercased()
    let transientMarkers = [
        "timed out after",
        "sqlitebuilddb.cpp",
        "org.swift.swiftpm/repositories",
        "indexstoredb",
        "unknown package",
    ]
    return transientMarkers.contains { normalized.contains($0) }
}

func isCrossArchStaticSDKMismatch(_ details: String) -> Bool {
    let normalized = details.lowercased()
    return normalized.contains("could not find module '_concurrency'")
        && normalized.contains("aarch64-swift-linux-musl")
        && normalized.contains("found: x86_64-swift-linux-musl")
}

private func runStaticLinuxBuild(repoRoot: String, buildPath: String, timeout: TimeInterval) throws -> String {
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: buildPath),
        withIntermediateDirectories: true
    )
    let swiftCLI = DevRuntime.preferredSwiftCLI
    print("Using Swift CLI: \(swiftCLI)")
    _ = try DevRuntime.requireSuccess(
        swiftCLI,
        try staticLinuxBuildArguments(buildPath: buildPath),
        cwd: repoRoot,
        timeout: timeout
    )

    let staticBuildOutput = try resolveLinuxAgentBinary(buildPath: buildPath)
    guard FileManager.default.fileExists(atPath: staticBuildOutput) else {
        throw DevCtlError.fileNotFound("Build artifact missing at \(staticBuildOutput)")
    }
    return staticBuildOutput
}

func staticLinuxBuildArguments(buildPath: String, linuxTargetTriple: String) -> [String] {
    [
        "build",
        "-c", "release",
        "--product", "nanoclaw-agent",
        "--skip-update",
        "--disable-automatic-resolution",
        "--swift-sdk", "swift-6.2.3-RELEASE_static-linux-0.0.1",
        "--triple", linuxTargetTriple,
        "--build-path", buildPath,
    ]
}

func staticLinuxBuildArguments(buildPath: String) throws -> [String] {
    let machine = currentMachineIdentifier()
    guard let triple = inferredLinuxMuslTargetTriple(machine: machine) else {
        throw ValidationError(
            "Unsupported host architecture '\(machine)' for static Linux build. " +
            "Supported host architectures: arm64, x86_64."
        )
    }
    return staticLinuxBuildArguments(buildPath: buildPath, linuxTargetTriple: triple)
}

func inferredLinuxMuslTargetTriple(machine: String) -> String? {
    switch machine.lowercased() {
    case "arm64", "aarch64":
        return "aarch64-swift-linux-musl"
    case "x86_64", "amd64":
        return "x86_64-swift-linux-musl"
    default:
        return nil
    }
}

func currentMachineIdentifier() -> String {
    var name = utsname()
    uname(&name)
    return withUnsafePointer(to: &name.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 1) { cString in
            String(cString: cString)
        }
    }
}

func resolveLinuxAgentBinary(buildPath: String) throws -> String {
    let exact = "\(buildPath)/nanoclaw-agent"
    if FileManager.default.fileExists(atPath: exact) {
        return exact
    }

    guard let enumerator = FileManager.default.enumerator(atPath: buildPath) else {
        throw DevCtlError.fileNotFound("Build path does not exist: \(buildPath)")
    }

    for case let path as String in enumerator {
        if URL(fileURLWithPath: path).lastPathComponent == "nanoclaw-agent" {
            return "\(buildPath)/\(path)"
        }
    }

    throw DevCtlError.fileNotFound("Could not locate nanoclaw-agent under \(buildPath)")
}
