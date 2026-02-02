import SwiftAgents
import Foundation

/// Simplified provider for OpenAI-compatible APIs (Kimi, OpenAI, Anthropic)
/// Includes retry logic with exponential backoff for 429 (rate limit) errors
public actor OpenAICompatibleProvider: InferenceProvider {
    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let timeout: Int
    private let urlSession: URLSession
    private let maxRetries: Int
    private let baseDelay: Double
    
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
        return try await chatCompletionWithRetry(messages: messages, options: options)
    }
    
    public func generateWithToolCalls(
        prompt: String,
        tools: [ToolDefinition],
        options: InferenceOptions
    ) async throws -> InferenceResponse {
        // For now, just generate without tools to avoid complexity
        // This is a placeholder - full tool support needs more work
        let content = try await generate(prompt: prompt, options: options)
        
        return InferenceResponse(
            content: content,
            toolCalls: [],
            finishReason: .completed,
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
    
    /// Performs chat completion with exponential backoff retry for 429 errors
    private func chatCompletionWithRetry(
        messages: [[String: String]],
        options: InferenceOptions
    ) async throws -> String {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await performChatCompletion(messages: messages, options: options)
            } catch let error as AgentError {
                lastError = error
                
                // Check if this is a 429 error (rate limited / overloaded)
                if case .generationFailed(let reason) = error,
                   reason.contains("429") {
                    // Calculate exponential backoff delay
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    print("[OpenAICompatibleProvider] Rate limited (429), attempt \(attempt + 1)/\(maxRetries). Retrying in \(String(format: "%.1f", delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    // Not a 429 error, don't retry
                    throw error
                }
            }
        }
        
        // Max retries exceeded
        throw lastError ?? AgentError.generationFailed(reason: "Max retries (\(maxRetries)) exceeded")
    }
    
    /// Performs a single chat completion attempt
    private func performChatCompletion(
        messages: [[String: String]],
        options: InferenceOptions
    ) async throws -> String {
        let request = try buildRequest(messages: messages, options: options)
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
        
        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AgentError.generationFailed(reason: "Failed to parse response")
        }
        
        return content
    }
    
    private func buildRequest(
        messages: [[String: String]],
        options: InferenceOptions
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": options.temperature,
            "max_tokens": options.maxTokens ?? 2048
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
