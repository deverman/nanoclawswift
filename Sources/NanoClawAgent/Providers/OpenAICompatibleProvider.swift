import SwiftAgents
import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider for OpenAI-compatible APIs (Kimi, OpenAI, Anthropic)
/// Includes retry logic with exponential backoff for 429 (rate limit) errors
/// Supports full tool calling with ReAct pattern
public actor OpenAICompatibleProvider: InferenceProvider {
    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let timeout: Int
    private let urlSession: URLSession
    private let maxRetries: Int
    private let baseDelay: Double
    private let logger = NanoClawLog.make("nanoclaw.provider.openai")
    
    public init(
        apiKey: String,
        baseURL: String,
        model: String,
        timeout: Int = 60,
        maxRetries: Int = 5,
        baseDelay: Double = 1.0
    ) {
        self.apiKey = apiKey
        self.baseURL = URL(string: baseURL)!
        self.model = model
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(timeout)
        config.timeoutIntervalForResource = TimeInterval(timeout * 2)
        self.urlSession = URLSession(configuration: config)
    }
    
    public func generate(
        prompt: String,
        options: InferenceOptions
    ) async throws -> String {
        let messages = [["role": "user", "content": prompt]]
        return try await chatCompletionWithRetry(messages: messages, options: options, tools: nil)
    }
    
    /// Generates a response with potential tool calls (ReAct pattern)
    public func generateWithToolCalls(
        prompt: String,
        tools: [ToolDefinition],
        options: InferenceOptions
    ) async throws -> InferenceResponse {
        let messages = [["role": "user", "content": prompt]]
        
        // Initial call with tools
        let (content, toolCalls, finishReason) = try await chatCompletionWithTools(
            messages: messages,
            tools: tools,
            options: options
        )
        
        return InferenceResponse(
            content: content,
            toolCalls: toolCalls,
            finishReason: finishReason,
            usage: nil
        )
    }
    
    nonisolated public func stream(
        prompt: String,
        options: InferenceOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let text = try await self.generate(prompt: prompt, options: options)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// Performs chat completion with optional tool support
    private func chatCompletionWithRetry(
        messages: [[String: String]],
        options: InferenceOptions,
        tools: [ToolDefinition]?
    ) async throws -> String {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                let (content, _, _) = try await performChatCompletion(
                    messages: messages,
                    options: options,
                    tools: tools
                )
                return content ?? ""
            } catch let error as AgentError {
                lastError = error
                
                // Check if this is a 429 error (rate limited / overloaded)
                if case .generationFailed(let reason) = error,
                   reason.contains("429") {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    logger.warning("Rate limited (429). Retrying.", metadata: [
                        "attempt": "\(attempt + 1)",
                        "maxRetries": "\(maxRetries)",
                        "delaySeconds": "\(String(format: "%.1f", delay))",
                        "model": "\(model)"
                    ])
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    throw error
                }
            }
        }
        
        throw lastError ?? AgentError.generationFailed(reason: "Max retries (\(maxRetries)) exceeded")
    }
    
    /// Performs chat completion and returns content + tool calls
    private func chatCompletionWithTools(
        messages: [[String: String]],
        tools: [ToolDefinition],
        options: InferenceOptions
    ) async throws -> (content: String?, toolCalls: [InferenceResponse.ParsedToolCall], finishReason: InferenceResponse.FinishReason) {
        let (content, parsedToolCalls, finishReason) = try await performChatCompletion(
            messages: messages,
            options: options,
            tools: tools
        )
        
        if ProcessInfo.processInfo.environment["NANOCLAW_DEBUG_TOOLS"] == "1" {
            print("[OpenAICompatibleProvider] Parsed tool calls: \(parsedToolCalls.count)")
        }
        return (content, parsedToolCalls, finishReason)
    }
    
    /// Performs a single chat completion attempt
    private func performChatCompletion(
        messages: [[String: String]],
        options: InferenceOptions,
        tools: [ToolDefinition]?
    ) async throws -> (content: String?, toolCalls: [InferenceResponse.ParsedToolCall], finishReason: InferenceResponse.FinishReason) {
        let request = try buildRequest(messages: messages, options: options, tools: tools)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError where urlError.code == .cannotFindHost {
            logger.error("DNS resolution failed for API host.", metadata: [
                "host": "\(baseURL.host ?? "unknown")",
                "model": "\(model)"
            ])
            throw urlError
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentError.generationFailed(reason: "Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AgentError.generationFailed(
                reason: "HTTP \(httpResponse.statusCode): \(body)"
            )
        }
        
        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            throw AgentError.generationFailed(reason: "Failed to parse response")
        }
        
        let message = firstChoice["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? String
        let finishReasonString = firstChoice["finish_reason"] as? String ?? "stop"
        
        let finishReason: InferenceResponse.FinishReason = finishReasonString == "tool_calls" ? .toolCall : .completed
        
        // Parse tool calls if present
        var parsedToolCalls: [InferenceResponse.ParsedToolCall] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let argumentsString = function["arguments"] as? String else {
                    continue
                }
                
                // Parse arguments JSON
                let arguments: [String: SendableValue]
                if let argsData = argumentsString.data(using: .utf8),
                   let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    var converted: [String: SendableValue] = [:]
                    for (key, value) in argsDict {
                        if let sendable = convertToSendableValue(value) {
                            converted[key] = sendable
                        }
                    }
                    arguments = converted
                } else {
                    arguments = [:]
                }
                
                parsedToolCalls.append(InferenceResponse.ParsedToolCall(
                    id: id,
                    name: name,
                    arguments: arguments
                ))
            }
        }
        
        return (content, parsedToolCalls, finishReason)
    }

    private func convertToSendableValue(_ value: Any) -> SendableValue? {
        if value is NSNull { return .null }
        if let str = value as? String { return .string(str) }
        if let bool = value as? Bool { return .bool(bool) }
        if let num = value as? NSNumber {
            // NSNumber can represent booleans as well.
            if num === true as NSNumber || num === false as NSNumber {
                return .bool(num.boolValue)
            }
            let doubleValue = num.doubleValue
            let intValue = num.int64Value
            if Double(intValue) == doubleValue {
                return .int(Int(intValue))
            }
            return .double(doubleValue)
        }
        if let array = value as? [Any] {
            return .array(array.compactMap { convertToSendableValue($0) })
        }
        if let dictionary = value as? [String: Any] {
            var converted: [String: SendableValue] = [:]
            for (key, item) in dictionary {
                if let sendable = convertToSendableValue(item) {
                    converted[key] = sendable
                }
            }
            return .dictionary(converted)
        }
        return nil
    }
    
    private func buildRequest(
        messages: [[String: String]],
        options: InferenceOptions,
        tools: [ToolDefinition]?
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Use max_completion_tokens for GPT-5.2+ models, max_tokens for older models
        let maxTokensKey = model.hasPrefix("gpt-5") ? "max_completion_tokens" : "max_tokens"
        
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": options.temperature,
            maxTokensKey: options.maxTokens ?? 2048
        ]
        
        // Add tools if provided
        if let tools = tools, !tools.isEmpty {
            let toolsArray = tools.map { tool -> [String: Any] in
                var parameters: [String: Any] = [:]
                
                // Convert ToolParameter array to JSON schema
                var properties: [String: Any] = [:]
                var required: [String] = []
                
                for param in tool.parameters {
                    var paramSchema = schema(for: param.type)
                    paramSchema["description"] = param.description
                    properties[param.name] = paramSchema
                    if param.isRequired {
                        required.append(param.name)
                    }
                }
                
                parameters = [
                    "type": "object",
                    "properties": properties
                ]
                if !required.isEmpty {
                    parameters["required"] = required
                }
                
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": parameters
                    ]
                ]
            }
            
            body["tools"] = toolsArray
            if let forcedTool = ProcessInfo.processInfo.environment["NANOCLAW_TOOL_CHOICE"], !forcedTool.isEmpty {
                body["tool_choice"] = [
                    "type": "function",
                    "function": ["name": forcedTool]
                ]
            } else {
                body["tool_choice"] = "auto"
            }
        }
        
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        if ProcessInfo.processInfo.environment["NANOCLAW_DEBUG_TOOLS"] == "1" {
            if let jsonString = String(data: bodyData, encoding: .utf8) {
                print("[OpenAICompatibleProvider] Request body: \(jsonString)")
            }
        }
        request.httpBody = bodyData
        return request
    }

    private func schema(for type: ToolParameter.ParameterType) -> [String: Any] {
        switch type {
        case .string:
            return ["type": "string"]
        case .int:
            return ["type": "integer"]
        case .double:
            return ["type": "number"]
        case .bool:
            return ["type": "boolean"]
        case let .array(elementType):
            return [
                "type": "array",
                "items": schema(for: elementType)
            ]
        case let .object(properties):
            var props: [String: Any] = [:]
            var required: [String] = []
            for param in properties {
                var paramSchema = schema(for: param.type)
                paramSchema["description"] = param.description
                props[param.name] = paramSchema
                if param.isRequired {
                    required.append(param.name)
                }
            }
            var schema: [String: Any] = [
                "type": "object",
                "properties": props
            ]
            if !required.isEmpty {
                schema["required"] = required
            }
            return schema
        case let .oneOf(options):
            return [
                "type": "string",
                "enum": options
            ]
        case .any:
            return ["type": "string"]
        }
    }
}
