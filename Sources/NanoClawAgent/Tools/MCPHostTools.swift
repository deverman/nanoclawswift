import Configuration
import Foundation
import SwiftAgents
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

typealias MCPHostRequestExecutor = @Sendable (
    _ endpoint: String,
    _ payload: [String: Any],
    _ environment: [String: String]
) async throws -> [String: Any]

private enum MCPHostToolConfig {
    static func brokerBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if #available(macOS 15.0, iOS 18.0, *) {
            let reader = ConfigReader(
                provider: EnvironmentVariablesProvider(environmentVariables: environment)
            )
            let value = reader.string(
                forKey: ConfigKey("NANOCLAW_MCP_HOST_BROKER_URL"),
                default: ""
            )
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let value = environment["NANOCLAW_MCP_HOST_BROKER_URL"] ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func mcpHostRequest(
    endpoint: String,
    payload: [String: Any],
    environment: [String: String] = ProcessInfo.processInfo.environment
) async throws -> [String: Any] {
    guard let rawBaseURL = MCPHostToolConfig.brokerBaseURL(environment: environment),
          let baseURL = URL(string: rawBaseURL) else {
        throw ToolError.executionFailed("NANOCLAW_MCP_HOST_BROKER_URL is not configured")
    }

    let url = baseURL.appendingPathComponent(endpoint)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 240
    let session = URLSession(configuration: config)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw ToolError.executionFailed("Host MCP bridge returned non-HTTP response")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ToolError.executionFailed("Host MCP bridge returned invalid JSON")
    }
    guard (200..<300).contains(http.statusCode) else {
        let message = (object["error"] as? String) ?? "HTTP \(http.statusCode)"
        throw ToolError.executionFailed("Host MCP bridge error (\(http.statusCode)): \(message)")
    }
    if let ok = object["ok"] as? Bool, !ok {
        let message = (object["error"] as? String) ?? "Host MCP bridge request failed"
        throw ToolError.executionFailed(message)
    }
    return object
}

private func resolveMCPConfigURL(
    explicitPath: String?,
    environment: [String: String]
) -> URL? {
    let explicitTrimmed = explicitPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let explicitTrimmed, !explicitTrimmed.isEmpty {
        let url = URL(fileURLWithPath: explicitTrimmed).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    if #available(macOS 15.0, iOS 18.0, *) {
        let reader = ConfigReader(
            provider: EnvironmentVariablesProvider(environmentVariables: environment)
        )
        let override = reader.string(forKey: ConfigKey("NANOCLAW_MCP_CONFIG_PATH"), default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    } else if let override = environment["NANOCLAW_MCP_CONFIG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty {
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

private func bridgeToolName(serverID: String, toolName: String) -> String {
    "mcp_\(sanitizeMCPIdentifier(serverID))_\(sanitizeMCPIdentifier(toolName))"
}

private func sanitizeMCPIdentifier(_ value: String) -> String {
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

private func intValue(from raw: Any?) -> Int? {
    if let int = raw as? Int {
        return int
    }
    if let number = raw as? NSNumber {
        return number.intValue
    }
    return nil
}

private func prettyHostMCPJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
          let text = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return text
}

public struct MCPHostCLITool: Tool, Sendable {
    public let name = "mcp_host_cli"
    public let description = "Runs CLI arguments against a configured host MCP server command"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "server_id", description: "Configured host MCP server id (from .mcp.json)", type: .string),
        ToolParameter(
            name: "args",
            description: "Optional command arguments to pass to the host MCP server binary",
            type: .array(elementType: .string),
            isRequired: false
        )
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let serverID = arguments["server_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverID.isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing server_id parameter")
        }

        let args = arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let response = try await mcpHostRequest(
            endpoint: "cli",
            payload: [
                "serverId": serverID,
                "args": args,
            ],
            environment: ProcessInfo.processInfo.environment
        )
        if let stdout = response["stdout"] as? String,
           !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .string(stdout)
        }
        return .string(prettyHostMCPJSON(response))
    }
}

public struct MCPReloadTool: Tool, Sendable {
    public let name = "mcp_reload"
    public let description = "Reloads MCP server config and reboots host MCP server registrations from .mcp.json"
    public let parameters: [ToolParameter] = [
        ToolParameter(
            name: "config_path",
            description: "Optional path to MCP config (defaults to NANOCLAW_MCP_CONFIG_PATH or /workspace/group/.mcp.json)",
            type: .string,
            isRequired: false
        )
    ]

    private let environment: [String: String]
    private let hostRequest: MCPHostRequestExecutor
    private let configResolver: @Sendable (_ explicitPath: String?, _ environment: [String: String]) -> URL?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hostRequest: @escaping MCPHostRequestExecutor = { endpoint, payload, environment in
            try await mcpHostRequest(endpoint: endpoint, payload: payload, environment: environment)
        },
        configResolver: @escaping @Sendable (_ explicitPath: String?, _ environment: [String: String]) -> URL? = { explicitPath, environment in
            resolveMCPConfigURL(explicitPath: explicitPath, environment: environment)
        }
    ) {
        self.environment = environment
        self.hostRequest = hostRequest
        self.configResolver = configResolver
    }

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let explicitPath = arguments["config_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configURL = configResolver(explicitPath, environment) else {
            throw ToolError.executionFailed(
                "MCP config not found. Checked config_path, NANOCLAW_MCP_CONFIG_PATH, /workspace/group/.mcp.json, /workspace/project/.mcp.json, and current-directory .mcp.json"
            )
        }

        let report = try MCPToolLoader.loadServers(from: configURL, environment: environment)
        var lines: [String] = [
            "MCP reload complete.",
            "Config path: \(configURL.path)",
            "Configured servers: container=\(report.containerServers.count), host=\(report.hostServers.count), skipped=\(report.skipped.count)"
        ]

        if !report.hostServers.isEmpty {
            let payloadServers: [[String: Any]] = report.hostServers.map { server in
                [
                    "id": server.id,
                    "command": server.command,
                    "args": server.arguments,
                    "env": server.environment,
                    "cwd": server.workingDirectory
                ]
            }
            let bootstrap = try await hostRequest(
                "bootstrap",
                ["servers": payloadServers],
                environment
            )
            let loadedServers = intValue(from: bootstrap["loadedServerCount"]) ?? 0
            let loadedTools = intValue(from: bootstrap["loadedToolCount"]) ?? 0
            lines.append("Host reload: loaded_servers=\(loadedServers), loaded_tools=\(loadedTools)")

            if let servers = bootstrap["servers"] as? [[String: Any]] {
                let bridgedNames = servers
                    .flatMap { server -> [String] in
                        guard let id = server["id"] as? String,
                              let tools = server["tools"] as? [[String: Any]] else {
                            return []
                        }
                        return tools.compactMap { tool in
                            guard let name = tool["name"] as? String else { return nil }
                            return bridgeToolName(serverID: id, toolName: name)
                        }
                    }
                    .sorted()

                if !bridgedNames.isEmpty {
                    lines.append("Loaded bridged tools: \(bridgedNames.joined(separator: ", "))")
                }
            }
        } else {
            lines.append("Host reload: no host MCP servers configured.")
        }

        if !report.containerServers.isEmpty {
            let containerServerIDs = report.containerServers.map(\.id).sorted().joined(separator: ", ")
            lines.append("Container MCP servers (loaded on next request): \(containerServerIDs)")
        }

        if !report.skipped.isEmpty {
            let skipped = report.skipped
                .map { "\($0.id)(\($0.reason.rawValue))" }
                .joined(separator: ", ")
            lines.append("Skipped: \(skipped)")
        }

        lines.append("Note: Newly added bridged MCP tools are available on the next agent request.")
        return .string(lines.joined(separator: "\n"))
    }
}
