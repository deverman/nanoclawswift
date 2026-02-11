import SwiftAgents
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct WebOverlayPolicy: Codable {
    var version: Int
    var allow: [String]
    var deny: [String]
}

private enum WebToolConfig {
    static let defaultBrokerURL = "http://192.168.64.1:18081/web"
    static let overlayRelativePath = ".nanoclaw/web-policy.overlay.json"

    static func groupFolder() -> String {
        ProcessInfo.processInfo.environment["NANOCLAW_GROUP_FOLDER"] ?? "unknown-group"
    }

    static func basePath() -> String {
        ProcessInfo.processInfo.environment["NANOCLAW_BASE_PATH"] ?? "/workspace/group"
    }

    static func overlayPath() -> String {
        "\(basePath())/\(overlayRelativePath)"
    }

    static func brokerBaseURL() -> String {
        ProcessInfo.processInfo.environment["NANOCLAW_WEB_BROKER_URL"] ?? defaultBrokerURL
    }
}

private func normalizeDomain(_ value: String) -> String? {
    var raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !raw.isEmpty else { return nil }

    if raw.contains("://"), let url = URL(string: raw), let host = url.host {
        raw = host.lowercased()
    }

    raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !raw.isEmpty else { return nil }

    if raw.hasPrefix("*.") {
        let base = String(raw.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !base.isEmpty else { return nil }
        return "*.\(base)"
    }

    return raw
}

private func loadOverlayPolicy() throws -> WebOverlayPolicy {
    let path = WebToolConfig.overlayPath()
    guard FileManager.default.fileExists(atPath: path) else {
        return WebOverlayPolicy(version: 1, allow: [], deny: [])
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(WebOverlayPolicy.self, from: data)
}

private func saveOverlayPolicy(_ policy: WebOverlayPolicy) throws {
    let path = WebToolConfig.overlayPath()
    let directory = (path as NSString).deletingLastPathComponent
    if !FileManager.default.fileExists(atPath: directory) {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory),
            withIntermediateDirectories: true
        )
    }

    let data = try JSONEncoder().encode(policy)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func headersDictionary(from value: SendableValue?) -> [String: String] {
    guard let dict = value?.dictionaryValue else { return [:] }
    var headers: [String: String] = [:]
    for (key, item) in dict {
        if let string = item.stringValue {
            headers[key] = string
        } else if let int = item.intValue {
            headers[key] = String(int)
        } else if let double = item.doubleValue {
            headers[key] = String(double)
        } else if let bool = item.boolValue {
            headers[key] = String(bool)
        }
    }
    return headers
}

private func performWebBrokerRequest(
    endpoint: String,
    payload: [String: Any]
) async throws -> [String: Any] {
    let base = WebToolConfig.brokerBaseURL().trimmingCharacters(in: .whitespacesAndNewlines)
    guard let baseURL = URL(string: base) else {
        throw ToolError.executionFailed("Invalid NANOCLAW_WEB_BROKER_URL: \(base)")
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
        throw ToolError.executionFailed("Web broker returned non-HTTP response")
    }

    let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if !(200..<300).contains(http.statusCode) {
        let brokerError = jsonObject?["error"] as? String
            ?? String(data: data, encoding: .utf8)
            ?? "Unknown web broker error"
        throw ToolError.executionFailed("Web broker error (\(http.statusCode)): \(brokerError)")
    }

    guard let jsonObject else {
        throw ToolError.executionFailed("Web broker returned invalid JSON")
    }

    if let ok = jsonObject["ok"] as? Bool, !ok {
        let message = jsonObject["error"] as? String ?? "Unknown web broker failure"
        throw ToolError.executionFailed(message)
    }

    return jsonObject
}

private func prettyJSONString(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
          let text = String(data: data, encoding: .utf8) else {
        return String(describing: object)
    }
    return text
}

public struct WebFetchTool: Tool, Sendable {
    public let name = "web_fetch"
    public let description = "Fetches a web page through the host web broker with policy checks"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "url", description: "URL to fetch (http/https)", type: .string),
        ToolParameter(
            name: "method",
            description: "HTTP method (default GET)",
            type: .oneOf(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]),
            isRequired: false,
            defaultValue: .string("GET")
        ),
        ToolParameter(
            name: "headers",
            description: "Optional request headers object",
            type: .object(properties: []),
            isRequired: false
        ),
        ToolParameter(
            name: "max_bytes",
            description: "Maximum response bytes to return",
            type: .int,
            isRequired: false
        )
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let url = arguments["url"]?.stringValue, !url.isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing url parameter")
        }

        let groupFolder = WebToolConfig.groupFolder()
        var payload: [String: Any] = [
            "groupFolder": groupFolder,
            "url": url
        ]

        if let method = arguments["method"]?.stringValue, !method.isEmpty {
            payload["method"] = method
        }

        let headers = headersDictionary(from: arguments["headers"])
        if !headers.isEmpty {
            payload["headers"] = headers
        }

        if let maxBytes = arguments["max_bytes"]?.intValue, maxBytes > 0 {
            payload["maxBytes"] = maxBytes
        }

        let response = try await performWebBrokerRequest(endpoint: "fetch", payload: payload)
        return .string(prettyJSONString(response))
    }
}

public struct WebSearchTool: Tool, Sendable {
    public let name = "web_search"
    public let description = "Searches the web via a provider-backed host broker endpoint"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "query", description: "Search query", type: .string),
        ToolParameter(name: "limit", description: "Maximum number of results", type: .int, isRequired: false)
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing query parameter")
        }

        let groupFolder = WebToolConfig.groupFolder()
        var payload: [String: Any] = [
            "groupFolder": groupFolder,
            "query": query
        ]

        if let limit = arguments["limit"]?.intValue, limit > 0 {
            payload["limit"] = limit
        }

        let response = try await performWebBrokerRequest(endpoint: "search", payload: payload)
        return .string(prettyJSONString(response))
    }
}

public struct WebPolicyAddDomainTool: Tool, Sendable {
    public let name = "web_policy_add_domain"
    public let description = "Adds a domain to this group's web policy overlay allowlist"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "domain", description: "Domain to allow (example.com or *.example.com)", type: .string),
        ToolParameter(name: "note", description: "Optional note for context", type: .string, isRequired: false)
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let domain = arguments["domain"]?.stringValue,
              let normalized = normalizeDomain(domain) else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Invalid domain parameter")
        }

        let note = arguments["note"]?.stringValue
        var overlay = try loadOverlayPolicy()
        if !overlay.allow.contains(normalized) {
            overlay.allow.append(normalized)
            overlay.allow.sort()
        }

        overlay.deny.removeAll(where: { $0 == normalized })
        try saveOverlayPolicy(overlay)

        let noteSuffix = note?.isEmpty == false ? " (note: \(note!))" : ""
        return .string(
            "Added \(normalized) to group web allowlist\(noteSuffix). Overlay: \(WebToolConfig.overlayPath())"
        )
    }
}

public struct WebPolicyRemoveDomainTool: Tool, Sendable {
    public let name = "web_policy_remove_domain"
    public let description = "Removes a domain from this group's web policy overlay"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "domain", description: "Domain to remove", type: .string)
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let domain = arguments["domain"]?.stringValue,
              let normalized = normalizeDomain(domain) else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Invalid domain parameter")
        }

        var overlay = try loadOverlayPolicy()
        let beforeAllow = overlay.allow.count
        let beforeDeny = overlay.deny.count
        overlay.allow.removeAll(where: { $0 == normalized })
        overlay.deny.removeAll(where: { $0 == normalized })
        try saveOverlayPolicy(overlay)

        let removed = (beforeAllow - overlay.allow.count) + (beforeDeny - overlay.deny.count)
        return .string(
            removed > 0
                ? "Removed \(normalized) from group web policy overlay"
                : "\(normalized) was not present in group web policy overlay"
        )
    }
}

public struct WebPolicyListTool: Tool, Sendable {
    public let name = "web_policy_list"
    public let description = "Lists global, overlay, and effective web policy for this group"
    public let parameters: [ToolParameter] = []

    public func execute(arguments _: [String: SendableValue]) async throws -> SendableValue {
        let payload: [String: Any] = [
            "groupFolder": WebToolConfig.groupFolder()
        ]
        let response = try await performWebBrokerRequest(endpoint: "policy/list", payload: payload)
        return .string(prettyJSONString(response))
    }
}
