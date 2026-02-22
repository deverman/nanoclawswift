import ArgumentParser
import Foundation
import Darwin

struct NanoClawHostCtl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nanoclaw-hostctl",
        abstract: "Swift-native lifecycle control for nanoclaw-host.",
        subcommands: [Start.self, Stop.self, Restart.self, Status.self, SchedulerDiagnostics.self]
    )
}

private enum HostCtlConstants {
    static let socketPath = "/tmp/nanoclaw-host.sock"
    static let pidFile = "/tmp/nanoclaw-host.pid"
    static let logFile = "/tmp/nanoclaw-host.log"
}

private func defaultStateRootPath() -> String {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config")
        .appendingPathComponent("clawclaw")
        .path
}

private enum HostCtlError: Error, LocalizedError {
    case startFailed(String)
    case binaryMissing(String)

    var errorDescription: String? {
        switch self {
        case .startFailed(let message):
            return message
        case .binaryMissing(let path):
            return "nanoclaw-host binary not found at \(path). Run `swift build --product nanoclaw-host`."
        }
    }
}

private struct HostCtlRuntime {
    let projectRoot: String
    let socketPath: String
    let pidFile: String
    let logFile: String

    var hostBinaryPath: String {
        "\(projectRoot)/.build/arm64-apple-macosx/debug/nanoclaw-host"
    }

    func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dotEnv = loadDotEnv(path: "\(projectRoot)/.env")
        for (key, value) in dotEnv where env[key] == nil {
            env[key] = value
        }
        // Reliability defaults (explicit env wins).
        if env["NANOCLAW_PREWARM_GROUP_SESSIONS"] == nil { env["NANOCLAW_PREWARM_GROUP_SESSIONS"] = "false" }
        if env["NANOCLAW_QUEUE_JOB_WATCHDOG_MS"] == nil { env["NANOCLAW_QUEUE_JOB_WATCHDOG_MS"] = "240000" }
        if env["NANOCLAW_SESSION_JANITOR_INTERVAL_SEC"] == nil { env["NANOCLAW_SESSION_JANITOR_INTERVAL_SEC"] = "15" }
        if env["NANOCLAW_STALE_CLAIM_REAP_AGE_SEC"] == nil { env["NANOCLAW_STALE_CLAIM_REAP_AGE_SEC"] = "90" }
        return env
    }

    func ensureContainerSystemRunning() {
        if runCommand("/usr/bin/env", ["container", "system", "status"], wait: true).status == 0 {
            return
        }
        _ = runCommand("/usr/bin/env", ["container", "system", "start"], wait: true)
    }

    func stopHost() {
        if let pid = readPID(path: pidFile) {
            terminate(pid: pid)
        }
        for pid in findHostPIDs(socketPath: socketPath) {
            terminate(pid: pid)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidFile)
    }

    func startHostInBackground() throws {
        ensureHostBinaryExists()
        ensureContainerSystemRunning()
        stopHost()

        let logURL = URL(fileURLWithPath: logFile)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: hostBinaryPath)
        process.arguments = ["--socket-path", socketPath, "--project-root", projectRoot]
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.environment = mergedEnvironment()
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        writePID(process.processIdentifier, path: pidFile)
    }

    func startHostInForeground() throws -> Never {
        ensureHostBinaryExists()
        ensureContainerSystemRunning()
        stopHost()
        let env = mergedEnvironment()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hostBinaryPath)
        process.arguments = ["--socket-path", socketPath, "--project-root", projectRoot]
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.environment = env
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput
        try process.run()
        writePID(process.processIdentifier, path: pidFile)
        process.waitUntilExit()
        Foundation.exit(process.terminationStatus)
    }

    func waitForHealthy(timeoutSeconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if isHealthy() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    func isHealthy() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        return unixSocketHealth(socketPath: socketPath)
    }

    func ensureHostBinaryExists() {
        if !FileManager.default.fileExists(atPath: hostBinaryPath) {
            _ = runCommand("/usr/bin/env", ["swift", "build", "--product", "nanoclaw-host"], wait: true)
        }
        guard FileManager.default.isExecutableFile(atPath: hostBinaryPath) else {
            NanoClawHostCtl.exit(withError: HostCtlError.binaryMissing(hostBinaryPath))
        }
    }
}

extension NanoClawHostCtl {
    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start nanoclaw-host.")

        @Option(name: .long)
        var projectRoot: String = FileManager.default.currentDirectoryPath

        @Option(name: .long)
        var socketPath: String = HostCtlConstants.socketPath

        @Option(name: .long)
        var pidFile: String = HostCtlConstants.pidFile

        @Option(name: .long)
        var logFile: String = HostCtlConstants.logFile

        @Flag(name: .long, help: "Run in foreground (replaces current process).")
        var foreground = false

        mutating func run() throws {
            let runtime = HostCtlRuntime(
                projectRoot: projectRoot,
                socketPath: socketPath,
                pidFile: pidFile,
                logFile: logFile
            )
            if foreground {
                _ = try runtime.startHostInForeground()
            } else {
                try runtime.startHostInBackground()
                guard runtime.waitForHealthy(timeoutSeconds: 20) else {
                    throw HostCtlError.startFailed("Host did not become healthy in time")
                }
                print("nanoclaw-host started (pid=\(readPID(path: pidFile) ?? -1), socket=\(socketPath))")
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop nanoclaw-host.")

        @Option(name: .long)
        var socketPath: String = HostCtlConstants.socketPath

        @Option(name: .long)
        var pidFile: String = HostCtlConstants.pidFile

        @Option(name: .long)
        var projectRoot: String = FileManager.default.currentDirectoryPath

        mutating func run() {
            let runtime = HostCtlRuntime(
                projectRoot: projectRoot,
                socketPath: socketPath,
                pidFile: pidFile,
                logFile: HostCtlConstants.logFile
            )
            runtime.stopHost()
            print("nanoclaw-host stopped")
        }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart nanoclaw-host.")

        @Option(name: .long)
        var projectRoot: String = FileManager.default.currentDirectoryPath

        @Option(name: .long)
        var socketPath: String = HostCtlConstants.socketPath

        @Option(name: .long)
        var pidFile: String = HostCtlConstants.pidFile

        @Option(name: .long)
        var logFile: String = HostCtlConstants.logFile

        @Flag(name: .long, help: "Run in foreground after restart.")
        var foreground = false

        mutating func run() throws {
            let runtime = HostCtlRuntime(
                projectRoot: projectRoot,
                socketPath: socketPath,
                pidFile: pidFile,
                logFile: logFile
            )
            runtime.stopHost()
            if foreground {
                _ = try runtime.startHostInForeground()
            } else {
                try runtime.startHostInBackground()
                guard runtime.waitForHealthy(timeoutSeconds: 20) else {
                    throw HostCtlError.startFailed("Host did not become healthy in time")
                }
                print("nanoclaw-host restarted (pid=\(readPID(path: pidFile) ?? -1), socket=\(socketPath))")
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show nanoclaw-host status.")

        @Option(name: .long)
        var projectRoot: String = FileManager.default.currentDirectoryPath

        @Option(name: .long)
        var socketPath: String = HostCtlConstants.socketPath

        @Option(name: .long)
        var pidFile: String = HostCtlConstants.pidFile

        mutating func run() {
            let runtime = HostCtlRuntime(
                projectRoot: projectRoot,
                socketPath: socketPath,
                pidFile: pidFile,
                logFile: HostCtlConstants.logFile
            )
            let pid = readPID(path: pidFile)
            let healthy = runtime.isHealthy()
            print("pid=\(pid.map(String.init) ?? "none")")
            print("socket=\(socketPath)")
            print("healthy=\(healthy)")
            Foundation.exit(healthy ? 0 : 1)
        }
    }

    struct SchedulerDiagnostics: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scheduler-diagnostics",
            abstract: "Show scheduler task state, recent task runs, and scheduler log evidence."
        )

        @Option(name: .long)
        var projectRoot: String = FileManager.default.currentDirectoryPath

        @Option(name: .long)
        var socketPath: String = HostCtlConstants.socketPath

        @Option(name: .long)
        var pidFile: String = HostCtlConstants.pidFile

        @Option(name: .long)
        var logFile: String = HostCtlConstants.logFile

        @Option(name: .long, help: "Optional explicit SQLite DB path (defaults to ~/.config/clawclaw/store/messages.db).")
        var dbPath: String?

        @Option(name: .long, help: "Optional task id filter.")
        var taskID: String?

        @Option(name: .long, help: "Maximum rows to print for tasks and run logs.")
        var limit: Int = 10

        mutating func run() throws {
            let runtime = HostCtlRuntime(
                projectRoot: projectRoot,
                socketPath: socketPath,
                pidFile: pidFile,
                logFile: logFile
            )
            let pid = readPID(path: pidFile)
            let healthy = runtime.isHealthy()
            let resolvedDBPath = dbPath ?? "\(defaultStateRootPath())/store/messages.db"
            let maxRows = max(1, min(limit, 100))
            let escapedTaskID = taskID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard FileManager.default.fileExists(atPath: resolvedDBPath) else {
                throw ValidationError("SQLite DB not found at \(resolvedDBPath)")
            }

            print("Scheduler diagnostics")
            print("host.pid=\(pid.map(String.init) ?? "none")")
            print("host.socket=\(socketPath)")
            print("host.healthy=\(healthy)")
            print("scheduler.model=swift-host-poll-loop (30s) + startup-catch-up")
            print("db.path=\(resolvedDBPath)")
            print("")

            let taskFilterClause: String = if escapedTaskID.isEmpty {
                ""
            } else {
                "WHERE id = '\(sqlEscape(escapedTaskID))'"
            }
            let taskSQL = """
            SELECT id, status, schedule_type, schedule_value, COALESCE(next_run, '') AS next_run, COALESCE(last_run, '') AS last_run, substr(COALESCE(last_result, ''), 1, 220) AS last_result
            FROM scheduled_tasks
            \(taskFilterClause)
            ORDER BY COALESCE(next_run, '9999-12-31T23:59:59Z') ASC
            LIMIT \(maxRows);
            """
            let taskRows = try sqliteJSONRows(dbPath: resolvedDBPath, sql: taskSQL)

            if taskRows.isEmpty {
                print("tasks=0")
            } else {
                print("tasks=\(taskRows.count)")
                for (index, row) in taskRows.enumerated() {
                    let id = stringField(row, "id")
                    let status = stringField(row, "status")
                    let scheduleType = stringField(row, "schedule_type")
                    let scheduleValue = stringField(row, "schedule_value")
                    let nextRun = stringField(row, "next_run")
                    let lastRun = stringField(row, "last_run")
                    let lastResult = stringField(row, "last_result")
                    let inferredCause: String = {
                        let trimmed = lastResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return "none" }
                        let lowered = trimmed.lowercased()
                        guard lowered.contains("error") || lowered.contains("failed") || lowered.contains("http ") else {
                            return "none"
                        }
                        return SchedulerDiagnosticsClassifier.classify(detail: trimmed).rawValue
                    }()
                    print("\(index + 1). \(id) [\(status)] \(scheduleType):\(scheduleValue)")
                    print("   next_run=\(nextRun.isEmpty ? "none" : nextRun)")
                    print("   last_run=\(lastRun.isEmpty ? "none" : lastRun)")
                    if !lastResult.isEmpty {
                        print("   last_result=\(lastResult)")
                    }
                    print("   inferred_failure_cause=\(inferredCause)")
                }
            }
            print("")

            let runFilterClause: String = if escapedTaskID.isEmpty {
                ""
            } else {
                "WHERE task_id = '\(sqlEscape(escapedTaskID))'"
            }
            let runsSQL = """
            SELECT task_id, run_at, status, duration_ms, substr(COALESCE(error, result, ''), 1, 220) AS detail
            FROM task_run_logs
            \(runFilterClause)
            ORDER BY run_at DESC
            LIMIT \(maxRows);
            """
            let runRows = try sqliteJSONRows(dbPath: resolvedDBPath, sql: runsSQL)
            if runRows.isEmpty {
                print("recent_runs=0")
            } else {
                print("recent_runs=\(runRows.count)")
                for (index, row) in runRows.enumerated() {
                    let runAt = stringField(row, "run_at")
                    let id = stringField(row, "task_id")
                    let status = stringField(row, "status")
                    let durationMs = stringField(row, "duration_ms")
                    let detail = stringField(row, "detail")
                    let cause = SchedulerDiagnosticsClassifier.classify(status: status, detail: detail)?.rawValue ?? "none"
                    print("\(index + 1). \(runAt) task=\(id) status=\(status) duration_ms=\(durationMs)")
                    if !detail.isEmpty {
                        print("   detail=\(detail)")
                    }
                    print("   inferred_failure_cause=\(cause)")
                }
            }
            print("")

            let schedulerLines = schedulerEvidenceLines(
                logFile: logFile,
                taskID: escapedTaskID.isEmpty ? nil : escapedTaskID,
                maxTailLines: max(2000, maxRows * 200),
                maxOutputLines: maxRows * 3
            )
            if schedulerLines.isEmpty {
                print("scheduler_log_evidence=none (log missing, unreadable, or no matching lines)")
            } else {
                print("scheduler_log_evidence=\(schedulerLines.count)")
                for line in schedulerLines {
                    print("- \(line)")
                }
            }
        }
    }
}

@discardableResult
private func runCommand(
    _ executable: String,
    _ arguments: [String],
    wait: Bool
) -> (status: Int32, process: Process) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    do {
        try process.run()
        if wait {
            process.waitUntilExit()
            return (process.terminationStatus, process)
        }
        return (0, process)
    } catch {
        return (1, process)
    }
}

private func loadDotEnv(path: String) -> [String: String] {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        return [:]
    }
    var values: [String: String] = [:]
    for line in raw.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        guard let idx = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        var value = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        if !key.isEmpty { values[key] = value }
    }
    return values
}

private func readPID(path: String) -> pid_t? {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          let value = Int32(raw), value > 0 else {
        return nil
    }
    return value
}

private func writePID(_ pid: pid_t, path: String) {
    try? "\(pid)\n".write(toFile: path, atomically: true, encoding: .utf8)
}

private func findHostPIDs(socketPath: String) -> [pid_t] {
    let result = runCommandOutput("/usr/bin/env", ["pgrep", "-f", "nanoclaw-host --socket-path \(socketPath)"])
    guard result.status == 0 else { return [] }
    return result.output
        .split(whereSeparator: \.isNewline)
        .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

private func terminate(pid: pid_t) {
    if kill(pid, 0) != 0 {
        return
    }
    _ = kill(pid, SIGTERM)
    for _ in 0..<20 {
        if kill(pid, 0) != 0 {
            return
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    _ = kill(pid, SIGKILL)
}

@discardableResult
private func runCommandOutput(
    _ executable: String,
    _ arguments: [String]
) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, output)
    } catch {
        return (1, "")
    }
}

private func unixSocketHealth(socketPath: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    if socketPath.utf8.count >= maxLen { return false }
    _ = socketPath.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: maxLen) { rebound in
                strncpy(rebound, src, maxLen - 1)
            }
        }
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult: Int32 = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(fd, sockaddrPtr, addrLen)
        }
    }
    if connectResult != 0 { return false }

    let request = "GET /v1/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    _ = request.withCString { cString in
        send(fd, cString, strlen(cString), 0)
    }

    var buffer = [UInt8](repeating: 0, count: 512)
    let count = recv(fd, &buffer, buffer.count, 0)
    if count <= 0 { return false }
    let text = String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
    return text.contains(" 200 ")
}

private func sqlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

private func sqliteJSONRows(dbPath: String, sql: String) throws -> [[String: Any]] {
    let result = runCommandOutput("/usr/bin/env", ["sqlite3", "-json", dbPath, sql])
    guard result.status == 0 else {
        throw ValidationError("sqlite3 query failed for \(dbPath): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard let data = trimmed.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data, options: []),
          let rows = raw as? [[String: Any]] else {
        throw ValidationError("sqlite3 returned non-JSON output")
    }
    return rows
}

private func stringField(_ row: [String: Any], _ key: String) -> String {
    if let value = row[key] as? String {
        return value
    }
    if let value = row[key] as? NSNumber {
        return value.stringValue
    }
    return ""
}

private func schedulerEvidenceLines(
    logFile: String,
    taskID: String?,
    maxTailLines: Int,
    maxOutputLines: Int
) -> [String] {
    guard FileManager.default.fileExists(atPath: logFile) else { return [] }
    guard let raw = try? String(contentsOfFile: logFile, encoding: .utf8) else { return [] }
    let candidateLines = raw
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .suffix(max(1, maxTailLines))

    let patterns = [
        "Scheduled catch-up enqueued",
        "Processing queue job request=sched-",
        "Completed scheduled queue job",
        "Scheduler catch-up failed"
    ]

    var matches = candidateLines
        .filter { line in
            patterns.contains { line.contains($0) }
        }

    if let taskID, !taskID.isEmpty {
        matches = matches.filter { line in
            line.contains(taskID) || line.contains("Scheduler catch-up")
        }
    }

    if matches.count > maxOutputLines {
        return Array(matches.suffix(maxOutputLines))
    }
    return matches
}

NanoClawHostCtl.main()
