import Configuration
import Foundation
import SwiftAgents
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum FocusRelayToolConfig {
    static let defaultBrokerURL = "http://192.168.64.1:18081/focusrelay"

    static func brokerBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if #available(macOS 15.0, iOS 18.0, *) {
            let reader = ConfigReader(
                provider: EnvironmentVariablesProvider(environmentVariables: environment)
            )
            let value = reader.string(
                forKey: ConfigKey("NANOCLAW_FOCUSRELAY_BROKER_URL"),
                default: defaultBrokerURL
            )
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (environment["NANOCLAW_FOCUSRELAY_BROKER_URL"] ?? defaultBrokerURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func focusRelayRequest(
    endpoint: String,
    payload: [String: Any]
) async throws -> [String: Any] {
    let base = FocusRelayToolConfig.brokerBaseURL()
    guard let baseURL = URL(string: base) else {
        throw ToolError.executionFailed("Invalid NANOCLAW_FOCUSRELAY_BROKER_URL: \(base)")
    }

    let url = baseURL.appendingPathComponent(endpoint)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120
    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 240
    let session = URLSession(configuration: config)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw ToolError.executionFailed("FocusRelay broker returned non-HTTP response")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ToolError.executionFailed("FocusRelay broker returned invalid JSON")
    }
    guard (200..<300).contains(http.statusCode) else {
        let message = (object["error"] as? String) ?? "HTTP \(http.statusCode)"
        throw ToolError.executionFailed("FocusRelay broker error (\(http.statusCode)): \(message)")
    }
    if let ok = object["ok"] as? Bool, !ok {
        let message = (object["error"] as? String) ?? "FocusRelay broker request failed"
        throw ToolError.executionFailed(message)
    }
    return object
}

private func prettyJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
          let text = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return text
}

private func renderInboxItems(_ items: [[String: Any]]) -> String {
    guard !items.isEmpty else {
        return "Inbox tasks: none."
    }

    var lines: [String] = ["Inbox tasks (\(items.count)):"]
    for (index, item) in items.enumerated() {
        let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(untitled)"
        let id = (item["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let available = (item["available"] as? Bool) == true ? "available" : "not available"
        let suffix = id.isEmpty ? "" : " [id: \(id)]"
        lines.append("\(index + 1). [\(available)] \(name)\(suffix)")
    }
    return lines.joined(separator: "\n")
}

public struct FocusRelayInboxTasksTool: Tool, Sendable {
    public let name = "focusrelay_inbox_tasks"
    public let description = "Lists OmniFocus inbox tasks using the host FocusRelay CLI bridge"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "limit", description: "Maximum number of inbox tasks to return (default 20, max 100)", type: .int, isRequired: false, defaultValue: .int(20)),
        ToolParameter(name: "available_only", description: "Return only available inbox tasks (default false)", type: .bool, isRequired: false, defaultValue: .bool(false))
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let limit = max(1, min(arguments["limit"]?.intValue ?? 20, 100))
        let availableOnly = arguments["available_only"]?.boolValue ?? false
        let response = try await focusRelayRequest(
            endpoint: "inbox",
            payload: [
                "limit": limit,
                "availableOnly": availableOnly,
            ]
        )
        let items = response["items"] as? [[String: Any]] ?? []
        return .string(renderInboxItems(items))
    }
}

public struct FocusRelayCLITool: Tool, Sendable {
    public let name = "focusrelay_cli"
    public let description = "Runs an allowlisted FocusRelay CLI subcommand on host and returns the output"
    public let parameters: [ToolParameter] = [
        ToolParameter(
            name: "subcommand",
            description: "FocusRelay subcommand",
            type: .oneOf([
                "list-tasks",
                "get-task",
                "list-projects",
                "list-tags",
                "task-counts",
                "project-counts",
                "debug-inbox-probe",
                "debug-inbox-probe-alt",
                "bridge-health-check",
            ])
        ),
        ToolParameter(
            name: "args",
            description: "Optional list of command arguments (for example: ['--inbox-only','true'])",
            type: .array(elementType: .string),
            isRequired: false
        )
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let subcommand = arguments["subcommand"]?.stringValue,
              !subcommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing subcommand parameter")
        }

        let args = arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let response = try await focusRelayRequest(
            endpoint: "cli",
            payload: [
                "subcommand": subcommand,
                "args": args,
            ]
        )

        if let stdout = response["stdout"] as? String,
           !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .string(stdout)
        }

        return .string(prettyJSON(response))
    }
}

public struct FocusRelayBridgeHealthTool: Tool, Sendable {
    public let name = "focusrelay_bridge_health"
    public let description = "Checks FocusRelay bridge/plugin health on host"
    public let parameters: [ToolParameter] = []

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        _ = arguments
        let response = try await focusRelayRequest(endpoint: "healthz", payload: [:])
        if let result = response["result"] {
            return .string(prettyJSON(result))
        }
        return .string(prettyJSON(response))
    }
}
