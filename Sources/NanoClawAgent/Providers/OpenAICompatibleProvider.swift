import SwiftAgents
import Foundation

/// Actor-based provider for OpenAI-compatible APIs (Kimi, OpenAI, Anthropic)
public actor OpenAICompatibleProvider: InferenceProvider {
    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let timeout: Int
    private let urlSession: URLSession
    
    public init(
        apiKey: String,
        baseURL: String,
        model: String,
        timeout: Int = 60
    ) {
        self.apiKey = apiKey
        self.baseURL = URL(string: baseURL)!
        self.model = model
        self.timeout = timeout
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(timeout)
        config.timeoutIntervalForResource = TimeInterval(timeout * 2)
        self.urlSession = URLSession(configuration: config)
    }
    
    public func generate(
        prompt: String,
        options: InferenceOptions
    ) async throws -> String {
        let messages = [ChatMessage(role: "user", content: prompt)]
        return try await chatCompletion(messages: messages, options: options, stream: false)
    }
    
    public func generateWithToolCalls(
        prompt: String,
        tools: [ToolDefinition],
        options: InferenceOptions
    ) async throws -> InferenceResponse {
        let messages = [ChatMessage(role: "user", content: prompt)]
        return try await chatCompletionWithTools(
            messages: messages,
            tools: tools,
            options: options
        )
    }
    
    nonisolated public func stream(
        prompt: String,
        options: InferenceOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let messages = [ChatMessage(role: "user", content: prompt)]
                    for try await chunk in try await self.streamCompletion(
                        messages: messages,
                        options: options
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func chatCompletion(
        messages: [ChatMessage],
        options: InferenceOptions,
        stream: Bool
    ) async throws -> String {
        let request = try buildRequest(messages: messages, options: options, stream: stream)
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentError.generationFailed(reason: "Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AgentError.generationFailed(
                reason: "HTTP \(httpResponse.statusCode): \(body)"
            )
        }
        
        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return completion.choices.first?.message.content ?? ""
    }
    
    private func chatCompletionWithTools(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        options: InferenceOptions
    ) async throws -> InferenceResponse {
        var request = try buildRequest(messages: messages, options: options, stream: false)
        
        // Add tools to request body
        let toolDicts = tools.map { tool -> [String: Any] in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                ]
            ]
        }
        
        // Decode existing body, add tools, re-encode
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        var newBody = body
        newBody["tools"] = toolDicts
        newBody["tool_choice"] = "auto"
        request.httpBody = try JSONSerialization.data(withJSONObject: newBody)
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentError.generationFailed(reason: "Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AgentError.generationFailed(
                reason: "HTTP \(httpResponse.statusCode): \(body)"
            )
        }
        
        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let choice = completion.choices.first!
        
        // Parse tool calls
        var toolCalls: [InferenceResponse.ParsedToolCall] = []
        if let calls = choice.message.tool_calls {
            toolCalls = calls.map { call in
                // Parse arguments JSON string into dictionary
                let args: [String: SendableValue]
                if let argsData = call.function.arguments.data(using: .utf8),
                   let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    args = argsDict.compactMapValues { value -> SendableValue? in
                        // Convert Any to SendableValue
                        if let str = value as? String {
                            return .string(str)
                        } else if let num = value as? NSNumber {
                            if num === true as NSNumber || num === false as NSNumber {
                                return .bool(num.boolValue)
                            } else if num.doubleValue == Double(num.int64Value) {
                                return .int(Int(num.int64Value))
                            } else {
                                return .double(num.doubleValue)
                            }
                        } else if let arr = value as? [Any] {
                            return .array(arr.compactMap { element -> SendableValue? in
                                if let str = element as? String { return .string(str) }
                                if let num = element as? NSNumber { return .int(Int(num.int64Value)) }
                                return nil
                            })
                        }
                        return nil
                    }
                } else {
                    args = [:]
                }
                
                return InferenceResponse.ParsedToolCall(
                    id: call.id,
                    name: call.function.name,
                    arguments: args
                )
            }
        }
        
        let finishReason: InferenceResponse.FinishReason = choice.finish_reason == "tool_calls" ? .toolCall : .completed
        
        return InferenceResponse(
            content: choice.message.content,
            toolCalls: toolCalls,
            finishReason: finishReason,
            usage: nil
        )
    }
    
    private func streamCompletion(
        messages: [ChatMessage],
        options: InferenceOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(messages: messages, options: options, stream: true)
                    let (bytes, response) = try await self.urlSession.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        throw AgentError.generationFailed(reason: "Stream request failed")
                    }
                    
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let data = String(line.dropFirst(6))
                            if data == "[DONE]" {
                                break
                            }
                            
                            if let chunkData = data.data(using: .utf8),
                               let chunk = try? JSONDecoder().decode(StreamChunk.self, from: chunkData),
                               let delta = chunk.choices.first?.delta.content {
                                continuation.yield(delta)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func buildRequest(
        messages: [ChatMessage],
        options: InferenceOptions,
        stream: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": options.temperature,
            "stream": stream
        ]
        
        if let maxTokens = options.maxTokens {
            body["max_tokens"] = maxTokens
        }
        
        if let topP = options.topP {
            body["top_p"] = topP
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

// MARK: - Types

private struct ChatMessage {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Codable {
    let choices: [Choice]
    let usage: Usage?
    
    struct Choice: Codable {
        let message: Message
        let finish_reason: String?
        
        struct Message: Codable {
            let content: String?
            let tool_calls: [ToolCall]?
            
            struct ToolCall: Codable {
                let id: String
                let function: Function
                
                struct Function: Codable {
                    let name: String
                    let arguments: String
                }
            }
        }
    }
    
    struct Usage: Codable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
}

private struct StreamChunk: Codable {
    let choices: [Choice]
    
    struct Choice: Codable {
        let delta: Delta
        
        struct Delta: Codable {
            let content: String?
        }
    }
}
