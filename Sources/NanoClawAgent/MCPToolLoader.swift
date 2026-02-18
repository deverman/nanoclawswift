import Foundation
import enum MCP.Value
import SwiftAgents

public enum MCPSkippedServerReason: String, Sendable, Equatable {
    case disabled
    case hostRuntimeUnsupported
    case hostBridgeUnavailable
    case hostBootstrapFailed
    case missingCommand
    case unsupportedTransport
    case unsupportedRuntime
}

public struct MCPSkippedServer: Sendable, Equatable {
    public let id: String
    public let reason: MCPSkippedServerReason

    public init(id: String, reason: MCPSkippedServerReason) {
        self.id = id
        self.reason = reason
    }
}

public struct MCPContainerServerLaunchSpec: Sendable, Equatable {
    public let id: String
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String

    public init(
        id: String,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct MCPContainerServerLoadReport: Sendable, Equatable {
    public let servers: [MCPContainerServerLaunchSpec]
    public let skipped: [MCPSkippedServer]

    public init(
        servers: [MCPContainerServerLaunchSpec],
        skipped: [MCPSkippedServer]
    ) {
        self.servers = servers
        self.skipped = skipped
    }
}

public struct MCPHostServerLaunchSpec: Sendable, Equatable {
    public let id: String
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String

    public init(
        id: String,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct MCPServerLoadReport: Sendable, Equatable {
    public let containerServers: [MCPContainerServerLaunchSpec]
    public let hostServers: [MCPHostServerLaunchSpec]
    public let skipped: [MCPSkippedServer]

    public init(
        containerServers: [MCPContainerServerLaunchSpec],
        hostServers: [MCPHostServerLaunchSpec],
        skipped: [MCPSkippedServer]
    ) {
        self.containerServers = containerServers
        self.hostServers = hostServers
        self.skipped = skipped
    }
}

public enum MCPToolLoader {
    public static func loadServers(
        from configURL: URL,
        containerWorkspace: URL = URL(fileURLWithPath: "/workspace/group"),
        environment: [String: String] = [:]
    ) throws -> MCPServerLoadReport {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return MCPServerLoadReport(containerServers: [], hostServers: [], skipped: [])
        }

        let data = try Data(contentsOf: configURL)
        let decoded = try JSONDecoder().decode(MCPConfigFile.self, from: data)

        var containerServers: [MCPContainerServerLaunchSpec] = []
        var hostServers: [MCPHostServerLaunchSpec] = []
        var skippedServers: [MCPSkippedServer] = []

        for serverID in decoded.mcpServers.keys.sorted() {
            let serverConfig = decoded.mcpServers[serverID] ?? MCPRawServerConfig()
            if serverConfig.disabled == true {
                skippedServers.append(MCPSkippedServer(id: serverID, reason: .disabled))
                continue
            }

            let runtime = serverConfig.normalizedRuntime
            let transport = serverConfig.normalizedTransport
            if transport != .stdio {
                skippedServers.append(MCPSkippedServer(id: serverID, reason: .unsupportedTransport))
                continue
            }

            guard let command = serverConfig.command?.trimmed, !command.isEmpty else {
                skippedServers.append(MCPSkippedServer(id: serverID, reason: .missingCommand))
                continue
            }

            let interpolatedCommand = interpolate(command, environment: environment)
            let interpolatedArgs = (serverConfig.args ?? []).map { interpolate($0, environment: environment) }
            let interpolatedEnv = (serverConfig.env ?? [:]).mapValues { interpolate($0, environment: environment) }

            switch runtime {
            case .container:
                let workingDirectory = resolveWorkingDirectory(
                    rawValue: serverConfig.cwd,
                    containerWorkspace: containerWorkspace,
                    environment: environment
                )
                containerServers.append(
                    MCPContainerServerLaunchSpec(
                        id: serverID,
                        command: interpolatedCommand,
                        arguments: interpolatedArgs,
                        environment: interpolatedEnv,
                        workingDirectory: workingDirectory
                    )
                )
            case .host:
                let workingDirectory = resolveHostWorkingDirectory(
                    rawValue: serverConfig.cwd,
                    environment: environment
                )
                hostServers.append(
                    MCPHostServerLaunchSpec(
                        id: serverID,
                        command: interpolatedCommand,
                        arguments: interpolatedArgs,
                        environment: interpolatedEnv,
                        workingDirectory: workingDirectory
                    )
                )
            case .unknown:
                skippedServers.append(MCPSkippedServer(id: serverID, reason: .unsupportedRuntime))
            }
        }

        return MCPServerLoadReport(
            containerServers: containerServers,
            hostServers: hostServers,
            skipped: skippedServers
        )
    }

    public static func loadContainerServers(
        from configURL: URL,
        containerWorkspace: URL = URL(fileURLWithPath: "/workspace/group"),
        environment: [String: String] = [:]
    ) throws -> MCPContainerServerLoadReport {
        let report = try loadServers(
            from: configURL,
            containerWorkspace: containerWorkspace,
            environment: environment
        )
        var skipped = report.skipped
        skipped.append(
            contentsOf: report.hostServers.map { spec in
                MCPSkippedServer(id: spec.id, reason: .hostRuntimeUnsupported)
            }
        )

        return MCPContainerServerLoadReport(
            servers: report.containerServers,
            skipped: skipped
        )
    }

    private static func resolveWorkingDirectory(
        rawValue: String?,
        containerWorkspace: URL,
        environment: [String: String]
    ) -> String {
        guard let rawValue = rawValue?.trimmed, !rawValue.isEmpty else {
            return containerWorkspace.path
        }

        let interpolated = interpolate(rawValue, environment: environment)
        if interpolated.hasPrefix("/") {
            return URL(fileURLWithPath: interpolated).standardized.path
        }

        return containerWorkspace
            .appendingPathComponent(interpolated)
            .standardized.path
    }

    private static func resolveHostWorkingDirectory(
        rawValue: String?,
        environment: [String: String]
    ) -> String {
        guard let rawValue = rawValue?.trimmed, !rawValue.isEmpty else {
            return ""
        }

        return interpolate(rawValue, environment: environment)
    }

    private static func interpolate(_ value: String, environment: [String: String]) -> String {
        guard !environment.isEmpty else { return value }

        let expression = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: expression) else {
            return value
        }

        let inputNSString = value as NSString
        let mutable = NSMutableString(string: value)
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: inputNSString.length))

        for match in matches.reversed() {
            let firstGroup = match.range(at: 1)
            let secondGroup = match.range(at: 2)
            let variableRange = firstGroup.location != NSNotFound ? firstGroup : secondGroup
            guard variableRange.location != NSNotFound else { continue }
            let variableName = inputNSString.substring(with: variableRange)
            guard let replacement = environment[variableName] else { continue }
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return mutable as String
    }
}

public struct MCPToolRegistration: Sendable, Hashable {
    public let serverID: String
    public let tool: MCPToolDescriptor

    public init(serverID: String, tool: MCPToolDescriptor) {
        self.serverID = serverID
        self.tool = tool
    }
}

public struct MCPToolDescriptor: Sendable, Hashable {
    public let name: String
    public let description: String?
    public let inputSchema: Value

    public init(name: String, description: String?, inputSchema: Value) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPToolExecutionResult: Sendable, Equatable {
    public let output: String
    public let isError: Bool

    public init(output: String, isError: Bool) {
        self.output = output
        self.isError = isError
    }
}

public protocol MCPToolExecutor: Sendable {
    func callTool(
        serverID: String,
        toolName: String,
        arguments: [String: Value]
    ) async throws -> MCPToolExecutionResult
}

public enum MCPToolRegistrationPipeline {
    public static func buildTools(
        registrations: [MCPToolRegistration],
        executor: any MCPToolExecutor
    ) -> [AnyTool] {
        registrations
            .sorted {
                if $0.serverID == $1.serverID {
                    return $0.tool.name < $1.tool.name
                }
                return $0.serverID < $1.serverID
            }
            .map { AnyTool(MCPBridgedTool(registration: $0, executor: executor)) }
    }
}

private struct MCPBridgedTool: Tool {
    let registration: MCPToolRegistration
    let executor: any MCPToolExecutor
    let parameters: [ToolParameter]

    init(registration: MCPToolRegistration, executor: any MCPToolExecutor) {
        self.registration = registration
        self.executor = executor
        self.parameters = MCPToolSchemaBridge.parameters(from: registration.tool.inputSchema)
    }

    var name: String {
        let server = MCPBridgedTool.sanitize(registration.serverID)
        let tool = MCPBridgedTool.sanitize(registration.tool.name)
        return "mcp_\(server)_\(tool)"
    }

    var description: String {
        if let description = registration.tool.description?.trimmed, !description.isEmpty {
            return "[MCP \(registration.serverID)] \(description)"
        }
        return "[MCP \(registration.serverID)] \(registration.tool.name)"
    }

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let mappedArguments = arguments.mapValues(MCPToolValueBridge.toMCPValue)
        let result = try await executor.callTool(
            serverID: registration.serverID,
            toolName: registration.tool.name,
            arguments: mappedArguments
        )

        if result.isError {
            throw AgentError.toolExecutionFailed(
                toolName: name,
                underlyingError: result.output.isEmpty ? "MCP tool returned an error" : result.output
            )
        }
        return .string(result.output)
    }

    private static func sanitize(_ value: String) -> String {
        var output = ""
        var previousWasUnderscore = false
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                previousWasUnderscore = false
            } else if !previousWasUnderscore {
                output.append("_")
                previousWasUnderscore = true
            }
        }

        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "tool" : trimmed.lowercased()
    }
}

private enum MCPToolSchemaBridge {
    static func parameters(from inputSchema: Value) -> [ToolParameter] {
        guard let schemaObject = inputSchema.objectValue,
              let properties = schemaObject["properties"]?.objectValue else {
            return []
        }
        let required = Set(schemaObject["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return parameters(from: properties, required: required)
    }

    private static func parameters(
        from properties: [String: Value],
        required: Set<String>
    ) -> [ToolParameter] {
        properties.keys.sorted().map { key in
            let definition = properties[key]?.objectValue ?? [:]
            return ToolParameter(
                name: key,
                description: definition["description"]?.stringValue ?? "MCP parameter \(key)",
                type: parameterType(from: definition),
                isRequired: required.contains(key),
                defaultValue: definition["default"].map(MCPToolValueBridge.toSendableValue)
            )
        }
    }

    private static func parameterType(from definition: [String: Value]) -> ToolParameter.ParameterType {
        if let enumValues = definition["enum"]?.arrayValue?.compactMap(\.stringValue),
           !enumValues.isEmpty {
            return .oneOf(enumValues)
        }

        let typeName = definition["type"]?.stringValue?.lowercased() ?? "any"
        switch typeName {
        case "string":
            return .string
        case "integer":
            return .int
        case "number":
            return .double
        case "boolean":
            return .bool
        case "array":
            let elementDefinition = definition["items"]?.objectValue ?? [:]
            return .array(elementType: parameterType(from: elementDefinition))
        case "object":
            let nestedProperties = definition["properties"]?.objectValue ?? [:]
            let nestedRequired = Set(definition["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return .object(properties: parameters(from: nestedProperties, required: nestedRequired))
        default:
            return .any
        }
    }
}

private enum MCPToolValueBridge {
    static func toMCPValue(_ value: SendableValue) -> Value {
        switch value {
        case .null:
            return .null
        case .bool(let boolValue):
            return .bool(boolValue)
        case .int(let intValue):
            return .int(intValue)
        case .double(let doubleValue):
            return .double(doubleValue)
        case .string(let stringValue):
            return .string(stringValue)
        case .array(let arrayValues):
            return .array(arrayValues.map(toMCPValue))
        case .dictionary(let dictionaryValues):
            return .object(dictionaryValues.mapValues(toMCPValue))
        }
    }

    static func toSendableValue(_ value: Value) -> SendableValue {
        switch value {
        case .null:
            return .null
        case .bool(let boolValue):
            return .bool(boolValue)
        case .int(let intValue):
            return .int(intValue)
        case .double(let doubleValue):
            return .double(doubleValue)
        case .string(let stringValue):
            return .string(stringValue)
        case .data(_, let dataValue):
            return .string(dataValue.base64EncodedString())
        case .array(let arrayValues):
            return .array(arrayValues.map(toSendableValue))
        case .object(let objectValues):
            return .dictionary(objectValues.mapValues(toSendableValue))
        }
    }
}

private struct MCPConfigFile: Decodable {
    let mcpServers: [String: MCPRawServerConfig]

    enum CodingKeys: String, CodingKey {
        case mcpServers
    }

    init(mcpServers: [String: MCPRawServerConfig] = [:]) {
        self.mcpServers = mcpServers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mcpServers = try container.decodeIfPresent([String: MCPRawServerConfig].self, forKey: .mcpServers) ?? [:]
    }
}

private struct MCPRawServerConfig: Decodable {
    enum Runtime: String {
        case container
        case host
        case unknown
    }

    enum Transport: String {
        case stdio
        case http
    }

    let command: String?
    let args: [String]?
    let env: [String: String]?
    let cwd: String?
    let disabled: Bool?
    let runtime: String?
    let transport: String?

    var normalizedRuntime: Runtime {
        Runtime(rawValue: (runtime ?? "container").lowercased()) ?? .unknown
    }

    var normalizedTransport: Transport {
        Transport(rawValue: (transport ?? "stdio").lowercased()) ?? .stdio
    }

    init(
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        cwd: String? = nil,
        disabled: Bool? = nil,
        runtime: String? = nil,
        transport: String? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.disabled = disabled
        self.runtime = runtime
        self.transport = transport
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
