import Configuration
import Foundation
import MCP
import SwiftAgents
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(System)
import System
private typealias MCPFileDescriptor = System.FileDescriptor
#elseif canImport(SystemPackage)
import SystemPackage
private typealias MCPFileDescriptor = SystemPackage.FileDescriptor
#endif

public struct MCPRuntimeBootstrap {
    public let tools: [AnyTool]
    public let diagnostics: [String]
    public let executor: MCPRuntimeExecutor?
    public let status: MCPRuntimeStatus

    public init(
        tools: [AnyTool],
        diagnostics: [String],
        executor: MCPRuntimeExecutor?,
        status: MCPRuntimeStatus
    ) {
        self.tools = tools
        self.diagnostics = diagnostics
        self.executor = executor
        self.status = status
    }
}

public struct MCPRuntimeStatus: Sendable, Equatable {
    public let hasConfig: Bool
    public let configuredServerCount: Int
    public let loadedServerIDs: [String]
    public let loadedToolCount: Int
    public let skippedServers: [MCPSkippedServer]
    public let diagnostics: [String]

    public init(
        hasConfig: Bool,
        configuredServerCount: Int,
        loadedServerIDs: [String],
        loadedToolCount: Int,
        skippedServers: [MCPSkippedServer],
        diagnostics: [String]
    ) {
        self.hasConfig = hasConfig
        self.configuredServerCount = configuredServerCount
        self.loadedServerIDs = loadedServerIDs
        self.loadedToolCount = loadedToolCount
        self.skippedServers = skippedServers
        self.diagnostics = diagnostics
    }

    public static let unconfigured = MCPRuntimeStatus(
        hasConfig: false,
        configuredServerCount: 0,
        loadedServerIDs: [],
        loadedToolCount: 0,
        skippedServers: [],
        diagnostics: []
    )
}

public actor MCPRuntimeExecutor: MCPToolExecutor {
    private struct ManagedServer {
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let client: Client
    }

    private var servers: [String: ManagedServer] = [:]

    func bootstrap(specs: [MCPContainerServerLaunchSpec]) async throws -> [MCPToolRegistration] {
        var registrations: [MCPToolRegistration] = []
        registrations.reserveCapacity(specs.count * 4)

        for spec in specs {
            let managed = try await startServer(spec: spec)
            servers[spec.id] = managed
            let discovered = try await listTools(client: managed.client)
            registrations.append(
                contentsOf: discovered.map { tool in
                    MCPToolRegistration(
                        serverID: spec.id,
                        tool: MCPToolDescriptor(
                            name: tool.name,
                            description: tool.description,
                            inputSchema: tool.inputSchema
                        )
                    )
                }
            )
        }

        return registrations
    }

    public func callTool(
        serverID: String,
        toolName: String,
        arguments: [String: Value]
    ) async throws -> MCPToolExecutionResult {
        guard let managed = servers[serverID] else {
            throw AgentError.toolExecutionFailed(
                toolName: "mcp_\(serverID)_\(toolName)",
                underlyingError: "MCP server \(serverID) is not connected"
            )
        }

        let response = try await managed.client.callTool(name: toolName, arguments: arguments)
        return MCPToolExecutionResult(
            output: Self.render(content: response.content),
            isError: response.isError ?? false
        )
    }

    private func startServer(spec: MCPContainerServerLaunchSpec) async throws -> ManagedServer {
        let process = Process()
        let launch = Self.resolveLaunchCommand(command: spec.command, arguments: spec.arguments)
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: spec.workingDirectory)
        if !spec.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe

        try process.run()

        let transport = StdioTransport(
            input: MCPFileDescriptor(rawValue: CInt(stdoutPipe.fileHandleForReading.fileDescriptor)),
            output: MCPFileDescriptor(rawValue: CInt(stdinPipe.fileHandleForWriting.fileDescriptor))
        )
        let client = Client(name: "nanoclaw-agent", version: "1.0.0")
        _ = try await client.connect(transport: transport)
        return ManagedServer(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            client: client
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

    private static func resolveLaunchCommand(command: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        if command.contains("/") {
            return (command, arguments)
        }
        return ("/usr/bin/env", [command] + arguments)
    }
}

private struct MCPHostRelayRuntimeExecutor: MCPToolExecutor {
    private let brokerBaseURL: URL
    private let session: URLSession

    init?(environment: [String: String]) {
        guard let rawURL = MCPRuntimeBootstrapLoader.envString("NANOCLAW_MCP_HOST_BROKER_URL", environment: environment),
              let parsedURL = URL(string: rawURL) else {
            return nil
        }
        self.brokerBaseURL = parsedURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 240
        self.session = URLSession(configuration: config)
    }

    func bootstrap(specs: [MCPHostServerLaunchSpec]) async throws -> [MCPToolRegistration] {
        let payloadServers: [[String: Any]] = specs.map { spec in
            [
                "id": spec.id,
                "command": spec.command,
                "args": spec.arguments,
                "env": spec.environment,
                "cwd": spec.workingDirectory,
            ]
        }

        let response = try await postJSON(
            path: "bootstrap",
            payload: ["servers": payloadServers]
        )

        guard let serverPayloads = response["servers"] as? [[String: Any]] else {
            throw AgentError.toolExecutionFailed(
                toolName: "mcp_host_bootstrap",
                underlyingError: "Host MCP bridge returned invalid bootstrap payload"
            )
        }

        var registrations: [MCPToolRegistration] = []
        for server in serverPayloads {
            guard let serverID = server["id"] as? String, !serverID.isEmpty else { continue }
            let tools = server["tools"] as? [[String: Any]] ?? []
            for tool in tools {
                guard let toolName = tool["name"] as? String, !toolName.isEmpty else { continue }
                let description = tool["description"] as? String
                let schemaObject = tool["inputSchema"] ?? ["type": "object"]
                let schemaValue = try mcpValue(fromJSON: schemaObject)
                registrations.append(
                    MCPToolRegistration(
                        serverID: serverID,
                        tool: MCPToolDescriptor(
                            name: toolName,
                            description: description,
                            inputSchema: schemaValue
                        )
                    )
                )
            }
        }
        return registrations
    }

    func callTool(
        serverID: String,
        toolName: String,
        arguments: [String: Value]
    ) async throws -> MCPToolExecutionResult {
        let renderedArguments = arguments.mapValues(jsonObject(fromMCPValue:))
        let response = try await postJSON(
            path: "call",
            payload: [
                "serverId": serverID,
                "toolName": toolName,
                "arguments": renderedArguments,
            ]
        )

        let output = (response["output"] as? String) ?? ""
        let isError = (response["isError"] as? Bool) ?? false
        return MCPToolExecutionResult(output: output, isError: isError)
    }

    func callCLI(
        serverID: String,
        args: [String]
    ) async throws -> String {
        let response = try await postJSON(
            path: "cli",
            payload: [
                "serverId": serverID,
                "args": args
            ]
        )
        if let stdout = response["stdout"] as? String, !stdout.isEmpty {
            return stdout
        }
        if let error = response["error"] as? String, !error.isEmpty {
            return error
        }
        if JSONSerialization.isValidJSONObject(response),
           let data = try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\(response)"
    }

    private func postJSON(path: String, payload: [String: Any]) async throws -> [String: Any] {
        let url = brokerBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentError.toolExecutionFailed(
                toolName: "mcp_host_bridge",
                underlyingError: "Host MCP bridge returned non-HTTP response"
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.toolExecutionFailed(
                toolName: "mcp_host_bridge",
                underlyingError: "Host MCP bridge returned invalid JSON"
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorMessage = (object["error"] as? String) ?? "HTTP \(httpResponse.statusCode)"
            throw AgentError.toolExecutionFailed(
                toolName: "mcp_host_bridge",
                underlyingError: errorMessage
            )
        }
        if let ok = object["ok"] as? Bool, !ok {
            let errorMessage = (object["error"] as? String) ?? "Host MCP bridge request failed"
            throw AgentError.toolExecutionFailed(
                toolName: "mcp_host_bridge",
                underlyingError: errorMessage
            )
        }
        return object
    }

    private func mcpValue(fromJSON raw: Any) throws -> Value {
        switch raw {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            let doubleValue = number.doubleValue
            if floor(doubleValue) == doubleValue {
                return .int(number.intValue)
            }
            return .double(doubleValue)
        case let array as [Any]:
            return .array(try array.map(mcpValue(fromJSON:)))
        case let dictionary as [String: Any]:
            var mapped: [String: Value] = [:]
            mapped.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                mapped[key] = try mcpValue(fromJSON: value)
            }
            return .object(mapped)
        default:
            throw AgentError.toolExecutionFailed(
                toolName: "mcp_host_bridge",
                underlyingError: "Unsupported JSON value in host MCP schema"
            )
        }
    }

    private func jsonObject(fromMCPValue value: Value) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .string(let string):
            return string
        case .data(_, let data):
            return data.base64EncodedString()
        case .array(let values):
            return values.map(jsonObject(fromMCPValue:))
        case .object(let dictionary):
            return dictionary.mapValues(jsonObject(fromMCPValue:))
        }
    }
}

public enum MCPRuntimeBootstrapLoader {
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> MCPRuntimeBootstrap {
        guard let configURL = resolveConfigURL(environment: environment) else {
            return MCPRuntimeBootstrap(
                tools: [],
                diagnostics: [],
                executor: nil,
                status: .unconfigured
            )
        }

        do {
            let loadReport = try MCPToolLoader.loadServers(
                from: configURL,
                environment: environment
            )
            var diagnostics: [String] = []
            var skippedServers = loadReport.skipped
            var allTools: [AnyTool] = []
            var loadedServerIDs: [String] = []
            let configuredServerCount = loadReport.containerServers.count + loadReport.hostServers.count + loadReport.skipped.count

            var containerExecutor: MCPRuntimeExecutor?
            if !loadReport.containerServers.isEmpty {
                let executor = MCPRuntimeExecutor()
                let registrations = try await executor.bootstrap(specs: loadReport.containerServers)
                let tools = MCPToolRegistrationPipeline.buildTools(
                    registrations: registrations,
                    executor: executor
                )
                containerExecutor = executor
                allTools.append(contentsOf: tools)
                loadedServerIDs.append(contentsOf: loadReport.containerServers.map(\.id))
                diagnostics.append("loaded_container_servers=\(loadReport.containerServers.count)")
                diagnostics.append("loaded_container_tools=\(tools.count)")
            }

            if !loadReport.hostServers.isEmpty {
                if let hostExecutor = MCPHostRelayRuntimeExecutor(environment: environment) {
                    do {
                        let hostRegistrations = try await hostExecutor.bootstrap(specs: loadReport.hostServers)
                        let hostTools = MCPToolRegistrationPipeline.buildTools(
                            registrations: hostRegistrations,
                            executor: hostExecutor
                        )
                        allTools.append(contentsOf: hostTools)
                        loadedServerIDs.append(contentsOf: loadReport.hostServers.map(\.id))
                        diagnostics.append("loaded_host_servers=\(loadReport.hostServers.count)")
                        diagnostics.append("loaded_host_tools=\(hostTools.count)")
                    } catch {
                        diagnostics.append("host_bootstrap_error=\(error.localizedDescription)")
                        skippedServers.append(
                            contentsOf: loadReport.hostServers.map { spec in
                                MCPSkippedServer(id: spec.id, reason: .hostBootstrapFailed)
                            }
                        )
                    }
                } else {
                    diagnostics.append("host_bridge_unavailable")
                    skippedServers.append(
                        contentsOf: loadReport.hostServers.map { spec in
                            MCPSkippedServer(id: spec.id, reason: .hostBridgeUnavailable)
                        }
                    )
                }
            }

            if !skippedServers.isEmpty {
                diagnostics.append(
                    "skipped=\(skippedServers.map { "\($0.id):\($0.reason.rawValue)" }.joined(separator: ","))"
                )
            }
            diagnostics.append("configured_servers=\(configuredServerCount)")

            return MCPRuntimeBootstrap(
                tools: allTools,
                diagnostics: diagnostics,
                executor: containerExecutor,
                status: MCPRuntimeStatus(
                    hasConfig: true,
                    configuredServerCount: configuredServerCount,
                    loadedServerIDs: loadedServerIDs,
                    loadedToolCount: allTools.count,
                    skippedServers: skippedServers,
                    diagnostics: diagnostics
                )
            )
        } catch {
            return MCPRuntimeBootstrap(
                tools: [],
                diagnostics: ["error=\(error.localizedDescription)"],
                executor: nil,
                status: MCPRuntimeStatus(
                    hasConfig: true,
                    configuredServerCount: 0,
                    loadedServerIDs: [],
                    loadedToolCount: 0,
                    skippedServers: [],
                    diagnostics: ["error=\(error.localizedDescription)"]
                )
            )
        }
    }

    private static func resolveConfigURL(environment: [String: String]) -> URL? {
        if let override = envString("NANOCLAW_MCP_CONFIG_PATH", environment: environment) {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let candidates = [
            URL(fileURLWithPath: "/workspace/group/.mcp.json"),
            URL(fileURLWithPath: "/workspace/project/.mcp.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".mcp.json")
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    fileprivate static func envString(_ key: String, environment: [String: String]) -> String? {
        if #available(macOS 15.0, iOS 18.0, *) {
            let reader = ConfigReader(
                provider: EnvironmentVariablesProvider(environmentVariables: environment)
            )
            let value = reader.string(forKey: ConfigKey(key), default: "")
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let value = environment[key] ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
