import Foundation
import Logging

struct HostRuntimeConfig: Sendable {
    let projectRoot: String
    let groupsDir: String
    let storeDir: String
    let containerImage: String
    let containerTimeoutMs: Int
    let containerPollMs: Int
    let queueJobWatchdogMs: Int
    let sessionJanitorIntervalSec: Int
    let staleClaimReapAgeSec: Int
    let containerPassthroughEnvironment: [String: String]
}

enum ContainerSessionError: Error, LocalizedError {
    case startupFailed(message: String)
    case requestFailed(message: String)
    case requestTimedOut(message: String)

    var errorDescription: String? {
        switch self {
        case .startupFailed(let message), .requestFailed(let message), .requestTimedOut(let message):
            return message
        }
    }
}

actor ContainerSessionManager {
    private final class GroupSession {
        let group: RegisteredGroupRow
        let containerName: String
        let process: Process
        let stdinPipe: Pipe
        let ipcRoot: URL
        let inputDir: URL
        let outputDir: URL
        let tasksDir: URL
        let messagesDir: URL
        let logFilePath: String

        init(
            group: RegisteredGroupRow,
            containerName: String,
            process: Process,
            stdinPipe: Pipe,
            ipcRoot: URL,
            inputDir: URL,
            outputDir: URL,
            tasksDir: URL,
            messagesDir: URL,
            logFilePath: String
        ) {
            self.group = group
            self.containerName = containerName
            self.process = process
            self.stdinPipe = stdinPipe
            self.ipcRoot = ipcRoot
            self.inputDir = inputDir
            self.outputDir = outputDir
            self.tasksDir = tasksDir
            self.messagesDir = messagesDir
            self.logFilePath = logFilePath
        }
    }

    private let config: HostRuntimeConfig
    private let logger: Logger
    private var sessions: [String: GroupSession] = [:]

    init(config: HostRuntimeConfig, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    nonisolated static func deterministicContainerName(for groupFolder: String) -> String {
        let sanitized = groupFolder
            .lowercased()
            .map { char -> Character in
                if char.isLetter || char.isNumber || char == "-" {
                    return char
                }
                return "-"
            }
        return "nanoclaw-\(String(sanitized))-active"
    }

    func activeSessionCount() -> Int {
        sessions.values.filter { $0.process.isRunning }.count
    }

    func ipcPaths(for groupFolder: String) -> (ipcRoot: URL, tasksDir: URL, messagesDir: URL)? {
        guard let session = sessions[groupFolder] else { return nil }
        return (ipcRoot: session.ipcRoot, tasksDir: session.tasksDir, messagesDir: session.messagesDir)
    }

    func ensureSession(for group: RegisteredGroupRow) async throws {
        if let existing = sessions[group.folder], existing.process.isRunning {
            return
        }
        if sessions[group.folder] != nil {
            sessions[group.folder] = nil
        }
        let session = try await startSession(for: group)
        sessions[group.folder] = session
    }

    func runRequest(
        group: RegisteredGroupRow,
        payload: ContainerRequestPayload,
        timeoutMs: Int?
    ) async throws -> ContainerResponsePayload {
        try await ensureSession(for: group)
        guard let session = sessions[group.folder] else {
            throw ContainerSessionError.startupFailed(message: "Session not available for \(group.folder)")
        }

        let requestFile = session.inputDir.appendingPathComponent("req-\(payload.request_id).json")
        let responseFile = session.outputDir.appendingPathComponent("res-\(payload.request_id).json")

        do {
            let data = try JSONEncoder().encode(payload)
            try atomicWrite(data: data, to: requestFile)
        } catch {
            throw ContainerSessionError.requestFailed(message: "Failed writing request file: \(error.localizedDescription)")
        }

        let timeout = timeoutMs ?? config.containerTimeoutMs
        let start = Date()

        while true {
            if FileManager.default.fileExists(atPath: responseFile.path) {
                do {
                    let data = try Data(contentsOf: responseFile)
                    try? FileManager.default.removeItem(at: responseFile)
                    return try JSONDecoder().decode(ContainerResponsePayload.self, from: data)
                } catch {
                    throw ContainerSessionError.requestFailed(message: "Failed reading response file: \(error.localizedDescription)")
                }
            }

            if !(session.process.isRunning) {
                sessions[group.folder] = nil
                let logTail = readLogTail(path: session.logFilePath)
                throw ContainerSessionError.requestFailed(
                    message: "Container session exited unexpectedly for \(group.folder). Check \(session.logFilePath)\(logTail)"
                )
            }

            if Int(Date().timeIntervalSince(start) * 1000) > timeout {
                // Timeout-after-output mitigation: check one last time before failing.
                if FileManager.default.fileExists(atPath: responseFile.path),
                   let data = try? Data(contentsOf: responseFile),
                   let response = try? JSONDecoder().decode(ContainerResponsePayload.self, from: data) {
                    try? FileManager.default.removeItem(at: responseFile)
                    return response
                }
                let logTail = readLogTail(path: session.logFilePath)
                throw ContainerSessionError.requestTimedOut(
                    message: "Timed out waiting for response (\(timeout)ms) for request \(payload.request_id).\nContainer log tail:\(logTail)"
                )
            }

            try? await Task.sleep(for: .milliseconds(config.containerPollMs))
        }
    }

    func stopAllSessions() async {
        let all = Array(sessions.values)
        sessions.removeAll()
        for session in all {
            await stopSession(session)
        }
    }

    func recycleSession(for groupFolder: String) async {
        guard let session = sessions.removeValue(forKey: groupFolder) else { return }
        await stopSession(session)
    }

    func sweepStaleContainers() async {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        command.arguments = ["container", "ls", "--all", "--format", "json"]
        let stdout = Pipe()
        let stderr = Pipe()
        command.standardOutput = stdout
        command.standardError = stderr

        do {
            try command.run()
            command.waitUntilExit()
            guard command.terminationStatus == 0 else { return }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return }
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            let entries: [[String: String]] = raw.compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let status = (entry["status"] as? String) ?? ""
                return ["name": name, "status": status]
            }

            let activeContainerNames = Set(sessions.values.map(\.containerName))
            let actions = ContainerSweepPlanner.plan(
                from: entries,
                activeSessionContainerNames: activeContainerNames
            )

            for action in actions {
                switch action {
                case .stopAndRemove(let name):
                    await stopAndRemoveContainer(name: name)
                case .remove(let name):
                    await removeContainer(name: name)
                }
            }
        } catch {
            logger.debug("Skipping stale container sweep: \(error.localizedDescription)")
        }
    }

    private func startSession(for group: RegisteredGroupRow) async throws -> GroupSession {
        let fileManager = FileManager.default
        let groupDir = URL(fileURLWithPath: config.groupsDir).appendingPathComponent(group.folder)
        let runtimeRoot = URL(fileURLWithPath: config.storeDir)
            .appendingPathComponent("runtime")
            .appendingPathComponent(group.folder)
        let ipcRoot = runtimeRoot.appendingPathComponent("ipc")
        let inputDir = ipcRoot.appendingPathComponent("input")
        let outputDir = ipcRoot.appendingPathComponent("output")
        let tasksDir = ipcRoot.appendingPathComponent("tasks")
        let messagesDir = ipcRoot.appendingPathComponent("messages")
        let sessionsDir = URL(fileURLWithPath: config.storeDir)
            .appendingPathComponent("sessions")
            .appendingPathComponent(group.folder)
            .appendingPathComponent(".claude")
        let logsDir = groupDir.appendingPathComponent("logs")
        let sharedMemoryDir = URL(fileURLWithPath: config.storeDir)
            .appendingPathComponent("shared-memory")

        try fileManager.createDirectory(at: groupDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedMemoryDir, withIntermediateDirectories: true)
        try cleanIpcRuntimeArtifacts(
            inputDir: inputDir,
            outputDir: outputDir,
            tasksDir: tasksDir,
            messagesDir: messagesDir,
            ipcRoot: ipcRoot
        )

        let timestamp = Int(Date().timeIntervalSince1970)
        let containerName = Self.deterministicContainerName(for: group.folder)
        let logFile = logsDir.appendingPathComponent("daemon-\(timestamp).log")
        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(atPath: logFile.path, contents: nil)
        }

        guard let logHandle = FileHandle(forWritingAtPath: logFile.path) else {
            throw ContainerSessionError.startupFailed(message: "Cannot open log file at \(logFile.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = URL(fileURLWithPath: config.projectRoot)

        await stopAndRemoveContainer(name: containerName)

        var args: [String] = ["container", "run", "-i", "--rm", "--name", containerName]
        args.append(contentsOf: ["-v", "\(groupDir.path):/workspace/group"])
        args.append(contentsOf: ["-v", "\(ipcRoot.path):/workspace/ipc"])
        args.append(contentsOf: ["-v", "\(sharedMemoryDir.path):/workspace/shared-memory"])
        args.append(contentsOf: ["-v", "\(sessionsDir.path):/home/nanoclaw/.claude"])
        if let hostSkillsRoot = Self.resolveHostSkillsRoot(
            projectRoot: config.projectRoot,
            passthroughEnvironment: config.containerPassthroughEnvironment
        ) {
            args.append(contentsOf: ["-v", "\(hostSkillsRoot):/home/nanoclaw/.codex/skills"])
            logger.info("Mounted skills root for group \(group.folder): \(hostSkillsRoot)")
        } else {
            logger.warning("No host skills root found for group \(group.folder). Skills tools will return 'skills root not found' until ~/.codex/skills exists.")
        }
        if let hostClaudeSkillsRoot = Self.resolveHostClaudeSkillsRoot(homePath: FileManager.default.homeDirectoryForCurrentUser.path) {
            args.append(contentsOf: ["-v", "\(hostClaudeSkillsRoot):/home/nanoclaw/.claude/skills"])
            logger.info("Mounted Claude skills root for group \(group.folder): \(hostClaudeSkillsRoot)")
        }

        if group.folder == "main" {
            args.append(contentsOf: ["-v", "\(config.projectRoot):/workspace/project"])
        }

        let containerEnvironment = buildContainerEnvironment(groupFolder: group.folder)
        if let relayBaseURL = containerEnvironment.first(where: { $0.hasPrefix("BASE_URL=") }) {
            logger.info("Container env relay target group=\(group.folder) \(relayBaseURL)")
        }
        if let modelProvider = containerEnvironment.first(where: { $0.hasPrefix("MODEL_PROVIDER=") }) {
            logger.info("Container env model provider group=\(group.folder) \(modelProvider)")
        }
        for envArgument in containerEnvironment {
            args.append(contentsOf: ["--env", envArgument])
        }

        args.append(config.containerImage)
        args.append(contentsOf: [
            "--config", "/workspace/config.json",
            "--group-folder", group.folder,
            "--chat-jid", group.jid,
            "--daemon"
        ])

        if group.folder == "main" {
            args.append("--is-main")
        }

        process.arguments = args
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw ContainerSessionError.startupFailed(
                message: "Failed to launch container for \(group.folder): \(error.localizedDescription)"
            )
        }

        logger.info("Started long-running container session \(containerName) for group \(group.folder)")
        return GroupSession(
            group: group,
            containerName: containerName,
            process: process,
            stdinPipe: stdinPipe,
            ipcRoot: ipcRoot,
            inputDir: inputDir,
            outputDir: outputDir,
            tasksDir: tasksDir,
            messagesDir: messagesDir,
            logFilePath: logFile.path
        )
    }

    private func stopSession(_ session: GroupSession) async {
        if session.process.isRunning {
            let closeSentinel = session.ipcRoot.appendingPathComponent("_close")
            try? atomicWrite(data: Data(), to: closeSentinel)

            let deadline = Date().addingTimeInterval(5)
            while session.process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }

            if session.process.isRunning {
                session.process.terminate()
                let hardDeadline = Date().addingTimeInterval(2)
                while session.process.isRunning, Date() < hardDeadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }

            if session.process.isRunning {
                kill(session.process.processIdentifier, SIGKILL)
            }
        }
        await removeContainer(name: session.containerName)
    }

    private func removeContainer(name: String) async {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        command.arguments = ["container", "rm", name]
        let stderr = Pipe()
        command.standardError = stderr
        do {
            try command.run()
            command.waitUntilExit()
            if command.terminationStatus == 0 {
                logger.info("Removed stale container \(name)")
            }
        } catch {
            logger.debug("Failed to remove stale container \(name): \(error.localizedDescription)")
        }
    }

    private func stopAndRemoveContainer(name: String) async {
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        stop.arguments = ["container", "stop", name]
        do {
            try stop.run()
            stop.waitUntilExit()
        } catch {
            logger.debug("Failed to stop stale container \(name): \(error.localizedDescription)")
        }
        await removeContainer(name: name)
    }

    private func buildContainerEnvironment(groupFolder: String) -> [String] {
        var env: [String] = []
        for key in HostEnvironmentConfig.containerPassthroughKeys {
            if let value = config.containerPassthroughEnvironment[key], !value.isEmpty {
                env.append("\(key)=\(value)")
            }
        }

        if !env.contains(where: { $0.hasPrefix("TIMEOUT=") }) {
            // Keep agent timeout below host-side container timeout, with a sane floor/ceiling.
            let hostTimeoutSeconds = max(30, config.containerTimeoutMs / 1000)
            var defaultAgentTimeout = min(180, max(45, hostTimeoutSeconds - 15))
            if defaultAgentTimeout >= hostTimeoutSeconds {
                defaultAgentTimeout = max(30, hostTimeoutSeconds - 5)
            }
            env.append("TIMEOUT=\(defaultAgentTimeout)")
        }

        env.append("NANOCLAW_GROUP_FOLDER=\(groupFolder)")
        env.append("NANOCLAW_BASE_PATH=/workspace/group")
        env.append("NANOCLAW_IPC_BASE_PATH=/workspace/ipc")
        env.append("NANOCLAW_SHARED_MEMORY_PATH=/workspace/shared-memory")
        env.append("NANOCLAW_GROUP_ISOLATED_MOUNT=1")
        env.append("CODEX_HOME=/home/nanoclaw/.codex")
        return env
    }

    nonisolated static func resolveHostSkillsRoot(
        projectRoot: String,
        passthroughEnvironment: [String: String],
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        let projectCodexSkills = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".codex")
            .appendingPathComponent("skills")
            .path
        let homeCodexSkills = URL(fileURLWithPath: homePath)
            .appendingPathComponent(".codex")
            .appendingPathComponent("skills")
            .path

        var candidates: [String] = []
        if let codexHome = passthroughEnvironment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            candidates.append(
                URL(fileURLWithPath: codexHome)
                    .appendingPathComponent("skills")
                    .path
            )
        }
        candidates.append(projectCodexSkills)
        candidates.append(homeCodexSkills)

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }

        return nil
    }

    nonisolated static func resolveHostClaudeSkillsRoot(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        let candidate = URL(fileURLWithPath: homePath)
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
            .path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = url.deletingPathExtension().appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private func cleanIpcRuntimeArtifacts(
        inputDir: URL,
        outputDir: URL,
        tasksDir: URL,
        messagesDir: URL,
        ipcRoot: URL
    ) throws {
        let fileManager = FileManager.default
        for directory in [inputDir, outputDir, tasksDir, messagesDir] {
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension == "json" {
                try? fileManager.removeItem(at: file)
            }
        }
        let closeSentinel = ipcRoot.appendingPathComponent("_close")
        if fileManager.fileExists(atPath: closeSentinel.path) {
            try? fileManager.removeItem(at: closeSentinel)
        }
    }

    private func readLogTail(path: String, maxBytes: Int = 8192) -> String {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              !data.isEmpty else {
            return " (no log output available)"
        }

        let slice: Data
        if data.count > maxBytes {
            slice = data.suffix(maxBytes)
        } else {
            slice = data
        }

        let text = String(data: slice, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(unreadable log bytes)"
        if text.isEmpty {
            return " (empty log output)"
        }
        return "\n\(text)"
    }
}
