import Foundation
import MCP

#if canImport(System)
import System
private typealias MCPFileDescriptor = System.FileDescriptor
#elseif canImport(SystemPackage)
import SystemPackage
private typealias MCPFileDescriptor = SystemPackage.FileDescriptor
#endif

actor HostMCPRuntime {
    struct ServerSpec: Sendable, Equatable {
        let id: String
        let command: String
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: String
    }

    struct ToolDescriptor: Sendable {
        let name: String
        let description: String?
        let inputSchema: MCP.Value
    }

    struct ServerSnapshot: Sendable {
        let id: String
        let tools: [ToolDescriptor]
    }

    struct BootstrapResult: Sendable {
        let servers: [ServerSnapshot]
        let diagnostics: [String]
    }

    struct ToolCallResult: Sendable {
        let output: String
        let isError: Bool
    }

    struct CLIRunResult: Sendable {
        let command: String
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let durationMs: Int
    }

    struct StatusSnapshot: Sendable {
        let serverIDs: [String]
        let toolCountByServer: [String: Int]
        let diagnostics: [String]
    }

    private struct ManagedServer {
        let spec: ServerSpec
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let client: Client
        let tools: [ToolDescriptor]
    }

    private var servers: [String: ManagedServer] = [:]
    private var diagnostics: [String] = []

    func bootstrap(specs: [ServerSpec]) async throws -> BootstrapResult {
        let desiredSpecs = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })

        let staleServerIDs = servers.keys.filter { desiredSpecs[$0] == nil }
        for serverID in staleServerIDs {
            guard let managed = servers.removeValue(forKey: serverID) else {
                continue
            }
            await stopServer(managed)
        }

        for spec in specs {
            if let current = servers[spec.id] {
                if !Self.shouldRestartServer(
                    currentSpec: current.spec,
                    desiredSpec: spec,
                    processIsRunning: current.process.isRunning
                ) {
                    continue
                }

                servers.removeValue(forKey: spec.id)
                await stopServer(current)
            }

            let managed = try await startServer(spec: spec)
            servers[spec.id] = managed
        }

        var snapshots: [ServerSnapshot] = []
        snapshots.reserveCapacity(specs.count)
        for spec in specs {
            if let managed = servers[spec.id] {
                snapshots.append(ServerSnapshot(id: spec.id, tools: managed.tools))
            }
        }
        diagnostics = [
            "loaded_servers=\(snapshots.count)",
            "loaded_tools=\(snapshots.reduce(0) { $0 + $1.tools.count })"
        ]
        return BootstrapResult(servers: snapshots, diagnostics: diagnostics)
    }

    func callTool(
        serverID: String,
        toolName: String,
        arguments: [String: MCP.Value]
    ) async throws -> ToolCallResult {
        guard let managed = servers[serverID] else {
            throw NSError(
                domain: "NanoClawHost.MCP",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "MCP server \(serverID) is not connected"]
            )
        }

        let response = try await managed.client.callTool(name: toolName, arguments: arguments)
        return ToolCallResult(
            output: Self.render(content: response.content),
            isError: response.isError ?? false
        )
    }

    func runCLI(
        serverID: String,
        arguments: [String]
    ) throws -> CLIRunResult {
        guard let managed = servers[serverID] else {
            throw NSError(
                domain: "NanoClawHost.MCP",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "MCP server \(serverID) is not connected"]
            )
        }

        return try Self.runCommand(
            command: managed.spec.command,
            arguments: arguments,
            environment: managed.spec.environment,
            workingDirectory: managed.spec.workingDirectory
        )
    }

    func status() -> StatusSnapshot {
        let ids = servers.keys.sorted()
        var counts: [String: Int] = [:]
        for id in ids {
            counts[id] = servers[id]?.tools.count ?? 0
        }
        return StatusSnapshot(
            serverIDs: ids,
            toolCountByServer: counts,
            diagnostics: diagnostics
        )
    }

    func shutdown() async {
        let existingServers = Array(servers.values)
        for managed in existingServers {
            await stopServer(managed)
        }
        servers.removeAll(keepingCapacity: false)
        diagnostics.removeAll(keepingCapacity: false)
    }

    private func startServer(spec: ServerSpec) async throws -> ManagedServer {
        let process = Process()
        let launch = Self.resolveLaunchCommand(command: spec.command, arguments: spec.arguments)
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: Self.resolveWorkingDirectory(spec.workingDirectory))
        process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()

        let transport = StdioTransport(
            input: MCPFileDescriptor(rawValue: CInt(stdoutPipe.fileHandleForReading.fileDescriptor)),
            output: MCPFileDescriptor(rawValue: CInt(stdinPipe.fileHandleForWriting.fileDescriptor))
        )
        let client = Client(name: "nanoclaw-host-mcp", version: "1.0.0")
        let tools: [ToolDescriptor]
        do {
            _ = try await client.connect(transport: transport)
            tools = try await listTools(client: client)
                .map { tool in
                    ToolDescriptor(
                        name: tool.name,
                        description: tool.description,
                        inputSchema: tool.inputSchema
                    )
                }
        } catch {
            await client.disconnect()
            terminate(process: process)
            throw error
        }

        return ManagedServer(
            spec: spec,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            client: client,
            tools: tools
        )
    }

    private func listTools(client: Client) async throws -> [MCP.Tool] {
        var tools: [MCP.Tool] = []
        var cursor: String? = nil
        repeat {
            let page = try await client.listTools(cursor: cursor)
            tools.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil
        return tools
    }

    private func terminate(process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func stopServer(_ managed: ManagedServer) async {
        await managed.client.disconnect()
        terminate(process: managed.process)
    }

    static func shouldRestartServer(
        currentSpec: ServerSpec,
        desiredSpec: ServerSpec,
        processIsRunning: Bool
    ) -> Bool {
        if currentSpec != desiredSpec {
            return true
        }
        return !processIsRunning
    }

    private static func resolveWorkingDirectory(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NSHomeDirectory()
        }

        let path: String
        if trimmed.hasPrefix("/") {
            path = URL(fileURLWithPath: trimmed).standardized.path
        } else {
            path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(trimmed)
                .standardized.path
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return NSHomeDirectory()
    }

    private static func resolveLaunchCommand(command: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        if command.contains("/") {
            return (command, arguments)
        }
        return ("/usr/bin/env", [command] + arguments)
    }

    private static func runCommand(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws -> CLIRunResult {
        let process = Process()
        let launch = resolveLaunchCommand(command: command, arguments: arguments)
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: resolveWorkingDirectory(workingDirectory))
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startedAt = Date()
        try process.run()
        process.waitUntilExit()
        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let renderedCommand = ([command] + arguments).joined(separator: " ")

        return CLIRunResult(
            command: renderedCommand,
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            durationMs: durationMs
        )
    }

    private static func render(content: [MCP.Tool.Content]) -> String {
        if content.isEmpty {
            return ""
        }

        return content.map { item in
            switch item {
            case .text(let text):
                return text
            case let .resource(uri, _, text):
                return text ?? "resource:\(uri)"
            case let .image(_, mimeType, _):
                return "image:\(mimeType)"
            case let .audio(_, mimeType):
                return "audio:\(mimeType)"
            }
        }.joined(separator: "\n")
    }
}
