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
    private let requestsPerMinuteLimit: Int?
    private var requestTimestamps: [Date] = []
    private let nowProvider: @Sendable () -> Date
    private let fallbackProvider: OpenAICompatibleProvider?
    private var consecutiveRateLimitFailures: Int = 0
    private var circuitOpenUntil: Date?
    private let logger = NanoClawLog.make("nanoclaw.provider.openai")

    struct RateLimitRetryPolicy: Sendable {
        let maxRetries: Int
        let baseDelaySeconds: Double
    }

    struct CircuitBreakerPolicy: Sendable {
        let openAfterConsecutive429: Int
        let cooldownSeconds: Double
    }

    struct FallbackEvent: Sendable, Equatable {
        let reason: String
    }
    
    public init(
        apiKey: String,
        baseURL: String,
        model: String,
        timeout: Int = 60,
        maxRetries: Int = 5,
        baseDelay: Double = 1.0,
        requestsPerMinuteLimit: Int? = nil,
        fallbackProvider: OpenAICompatibleProvider? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKey = apiKey
        self.baseURL = URL(string: baseURL)!
        self.model = model
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.requestsPerMinuteLimit = requestsPerMinuteLimit
        self.fallbackProvider = fallbackProvider
        self.nowProvider = nowProvider
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(timeout)
        config.timeoutIntervalForResource = TimeInterval(timeout * 2)
        self.urlSession = URLSession(configuration: config)
    }

    static func chatCompletionsURL(baseURL: URL) -> URL {
        var cleaned = baseURL.absoluteString
        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        return URL(string: "\(cleaned)/chat/completions")!
    }

    static func forcedToolChoice(
        fromMessages messages: [[String: String]],
        tools: [ToolDefinition],
        environment: [String: String]
    ) -> String? {
        if let explicit = environment["NANOCLAW_TOOL_CHOICE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        guard !tools.isEmpty else { return nil }
        let namesByLower = Dictionary(uniqueKeysWithValues: tools.map { ($0.name.lowercased(), $0.name) })
        let promptText = messages
            .compactMap { $0["content"]?.lowercased() }
            .joined(separator: "\n")

        let patterns = [
            #"`([a-z0-9_-]{2,})`\s+tool"#,
            #"use\s+(?:the\s+)?([a-z0-9_-]{2,})\s+tool"#,
            #"call\s+(?:the\s+)?([a-z0-9_-]{2,})\s+tool"#,
            #"run\s+(?:the\s+)?([a-z0-9_-]{2,})\s+tool"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(promptText.startIndex..<promptText.endIndex, in: promptText)
            guard let match = regex.firstMatch(in: promptText, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: promptText) else {
                continue
            }
            let captured = String(promptText[captureRange]).lowercased()
            if let resolved = namesByLower[captured] {
                return resolved
            }
        }

        return nil
    }

    static func supportsForcedToolChoice(model: String, host: String) -> Bool {
        let normalizedModel = model.lowercased()
        let normalizedHost = host.lowercased()
        if normalizedModel.hasPrefix("kimi") || normalizedHost.contains("moonshot") {
            return false
        }
        return true
    }

    static func throttleDelaySeconds(
        now: Date,
        recentRequests: [Date],
        limitPerMinute: Int
    ) -> Double {
        guard limitPerMinute > 0 else { return 0 }
        let windowStart = now.addingTimeInterval(-60)
        let active = recentRequests.filter { $0 >= windowStart }.sorted()
        guard active.count >= limitPerMinute,
              let oldestWithinLimit = active.first else {
            return 0
        }
        let earliestNext = oldestWithinLimit.addingTimeInterval(60)
        return max(0, earliestNext.timeIntervalSince(now))
    }

    static func rateLimitRetryPolicy() -> RateLimitRetryPolicy {
        // Keep rate-limit retries very conservative to avoid amplifying org-level contention.
        // maxRetries is total attempts in this loop, so 2 => one retry.
        RateLimitRetryPolicy(maxRetries: 2, baseDelaySeconds: 2.0)
    }

    static func spacingDelaySeconds(
        now: Date,
        recentRequests: [Date],
        limitPerMinute: Int
    ) -> Double {
        guard limitPerMinute > 0 else { return 0 }
        guard let latest = recentRequests.max() else { return 0 }
        let minSpacing = 60.0 / Double(limitPerMinute)
        let elapsed = now.timeIntervalSince(latest)
        return max(0, minSpacing - elapsed)
    }

    static func circuitBreakerPolicy() -> CircuitBreakerPolicy {
        CircuitBreakerPolicy(openAfterConsecutive429: 2, cooldownSeconds: 30)
    }

    static func remainingCooldownSeconds(now: Date, openUntil: Date?) -> Double {
        guard let openUntil else { return 0 }
        return max(0, openUntil.timeIntervalSince(now))
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
        let requestTraceID = UUID().uuidString
        let rateLimitPolicy = Self.rateLimitRetryPolicy()
        let effectiveMaxRetries = min(maxRetries, rateLimitPolicy.maxRetries)
        
        for attempt in 0..<effectiveMaxRetries {
            do {
                let (content, _, _) = try await performChatCompletion(
                    messages: messages,
                    options: options,
                    tools: tools,
                    requestTraceID: requestTraceID
                )
                resetRateLimitState()
                return content ?? ""
            } catch let error as AgentError {
                lastError = error
                
                // Check if this is a 429 error (rate limited / overloaded)
                if case .generationFailed(let reason) = error,
                   reason.contains("429") {
                    let exponentialDelay = rateLimitPolicy.baseDelaySeconds * pow(2.0, Double(attempt))
                    let providerSuggestedDelay = Self.parseRetryAfterSeconds(from: reason) ?? 0
                    let delay = max(exponentialDelay, providerSuggestedDelay)
                    logger.warning("Rate limited (429). Retrying.", metadata: [
                        "requestTraceID": "\(requestTraceID)",
                        "attempt": "\(attempt + 1)",
                        "maxRetries": "\(effectiveMaxRetries)",
                        "delaySeconds": "\(String(format: "%.1f", delay))",
                        "providerDelaySeconds": "\(String(format: "%.1f", providerSuggestedDelay))",
                        "model": "\(model)"
                    ])
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    throw error
                }
            }
        }

        if let error = lastError,
           shouldUseFallback(for: error),
           let fallbackProvider {
            await ProviderRequestDiagnosticsContext.current?.recordFallback(reason: "primary_exhausted")
            logger.warning("Primary provider exhausted; attempting fallback provider.", metadata: [
                "requestTraceID": "\(requestTraceID)",
                "primaryModel": "\(model)"
            ])
            return try await fallbackProvider.chatCompletionWithRetry(
                messages: messages,
                options: options,
                tools: tools
            )
        }

        throw lastError ?? AgentError.generationFailed(reason: "Max retries (\(effectiveMaxRetries)) exceeded")
    }

    static func parseRetryAfterSeconds(from reason: String) -> Double? {
        let pattern = #"try again after\s+([0-9]+(?:\.[0-9]+)?)\s+seconds?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(reason.startIndex..<reason.endIndex, in: reason)
        guard let match = regex.firstMatch(in: reason, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: reason) else {
            return nil
        }
        return Double(reason[valueRange])
    }
    
    /// Performs chat completion and returns content + tool calls
    private func chatCompletionWithTools(
        messages: [[String: String]],
        tools: [ToolDefinition],
        options: InferenceOptions
    ) async throws -> (content: String?, toolCalls: [InferenceResponse.ParsedToolCall], finishReason: InferenceResponse.FinishReason) {
        let requestTraceID = UUID().uuidString
        var content: String?
        var parsedToolCalls: [InferenceResponse.ParsedToolCall]
        var finishReason: InferenceResponse.FinishReason
        do {
            (content, parsedToolCalls, finishReason) = try await performChatCompletion(
                messages: messages,
                options: options,
                tools: tools,
                requestTraceID: requestTraceID
            )
            resetRateLimitState()
        } catch {
            if shouldUseFallback(for: error), let fallbackProvider {
                await ProviderRequestDiagnosticsContext.current?.recordFallback(reason: "tool_call_error")
                logger.warning("Primary provider tool call failed; attempting fallback provider.", metadata: [
                    "requestTraceID": "\(requestTraceID)",
                    "primaryModel": "\(model)"
                ])
                (content, parsedToolCalls, finishReason) = try await fallbackProvider.chatCompletionWithTools(
                    messages: messages,
                    tools: tools,
                    options: options
                )
            } else {
                throw error
            }
        }
        
        if ProcessInfo.processInfo.environment["NANOCLAW_DEBUG_TOOLS"] == "1" {
            print("[OpenAICompatibleProvider] Parsed tool calls: \(parsedToolCalls.count)")
        }
        if shouldUseFallbackForBehavioralToolFailure(
            content: content,
            parsedToolCalls: parsedToolCalls,
            finishReason: finishReason,
            tools: tools
        ), let fallbackProvider {
            await ProviderRequestDiagnosticsContext.current?.recordFallback(reason: "behavioral_tool_failure")
            logger.warning("Primary provider produced non-actionable tool response; attempting fallback provider.", metadata: [
                "requestTraceID": "\(requestTraceID)",
                "primaryModel": "\(model)"
            ])
            return try await fallbackProvider.chatCompletionWithTools(
                messages: messages,
                tools: tools,
                options: options
            )
        }
        return (content, parsedToolCalls, finishReason)
    }
    
    /// Performs a single chat completion attempt
    private func performChatCompletion(
        messages: [[String: String]],
        options: InferenceOptions,
        tools: [ToolDefinition]?,
        requestTraceID: String
    ) async throws -> (content: String?, toolCalls: [InferenceResponse.ParsedToolCall], finishReason: InferenceResponse.FinishReason) {
        try enforceCircuitBreakerIfOpen(requestTraceID: requestTraceID)
        try await applyRequestThrottleIfNeeded(requestTraceID: requestTraceID)

        let request = try buildRequest(messages: messages, options: options, tools: tools)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError where urlError.code == .cannotFindHost {
            logger.error("DNS resolution failed for API host.", metadata: [
                "requestTraceID": "\(requestTraceID)",
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
            if httpResponse.statusCode == 429 {
                let reason = "HTTP \(httpResponse.statusCode): \(body)"
                recordRateLimitFailure(reason: reason, requestTraceID: requestTraceID)
            }
            throw AgentError.generationFailed(
                reason: "HTTP \(httpResponse.statusCode): \(body)"
            )
        }
        resetRateLimitState()
        
        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            throw AgentError.generationFailed(reason: "Failed to parse response")
        }
        
        let message = firstChoice["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? String
        let finishReasonString = firstChoice["finish_reason"] as? String ?? "stop"
        
        var finishReason: InferenceResponse.FinishReason = finishReasonString == "tool_calls" ? .toolCall : .completed
        
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

        if parsedToolCalls.isEmpty, let content {
            let recoveredPseudoCalls = Self.recoverPseudoToolCalls(from: content)
            if !recoveredPseudoCalls.isEmpty {
                parsedToolCalls = recoveredPseudoCalls
                finishReason = .toolCall
                logger.warning("Recovered pseudo tool syntax into structured tool calls.", metadata: [
                    "model": "\(model)",
                    "recoveredCount": "\(recoveredPseudoCalls.count)"
                ])
            } else if Self.containsPseudoToolSyntax(content) {
                logger.warning("Model returned pseudo tool syntax in text without structured tool_calls.", metadata: [
                    "model": "\(model)"
                ])
            }
        }
        
        return (content, parsedToolCalls, finishReason)
    }

    private func shouldUseFallback(for error: Error) -> Bool {
        if let agentError = error as? AgentError,
           case .generationFailed(let reason) = agentError {
            return reason.contains("429")
                || reason.localizedCaseInsensitiveContains("temporarily unavailable due to rate limits")
        }
        return false
    }

    private func shouldUseFallbackForBehavioralToolFailure(
        content: String?,
        parsedToolCalls: [InferenceResponse.ParsedToolCall],
        finishReason: InferenceResponse.FinishReason,
        tools: [ToolDefinition]
    ) -> Bool {
        guard !tools.isEmpty else { return false }
        guard parsedToolCalls.isEmpty else { return false }
        if finishReason == .toolCall {
            return true
        }
        guard let content else { return false }
        return Self.containsCapabilityLimitationDisclaimer(content)
            || Self.containsPseudoToolSyntax(content)
    }

    nonisolated static func containsCapabilityLimitationDisclaimer(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let markers = [
            "i don't have access",
            "i do not have access",
            "can't access",
            "cannot access",
            "in this environment",
            "real-time web search",
            "live data"
        ]
        return markers.contains(where: { normalized.contains($0) })
    }

    private func enforceCircuitBreakerIfOpen(requestTraceID: String) throws {
        let now = nowProvider()
        let remaining = Self.remainingCooldownSeconds(now: now, openUntil: circuitOpenUntil)
        guard remaining > 0 else {
            circuitOpenUntil = nil
            return
        }

        logger.warning("Provider circuit breaker open; rejecting request.", metadata: [
            "requestTraceID": "\(requestTraceID)",
            "retryAfterSeconds": "\(String(format: "%.1f", remaining))",
            "model": "\(model)"
        ])
        throw AgentError.generationFailed(
            reason: "Provider temporarily unavailable due to rate limits. Retry after \(Int(ceil(remaining))) seconds."
        )
    }

    private func resetRateLimitState() {
        consecutiveRateLimitFailures = 0
        circuitOpenUntil = nil
    }

    private func recordRateLimitFailure(reason: String, requestTraceID: String) {
        consecutiveRateLimitFailures += 1
        let policy = Self.circuitBreakerPolicy()
        guard consecutiveRateLimitFailures >= policy.openAfterConsecutive429 else { return }

        let providerHint = Self.parseRetryAfterSeconds(from: reason) ?? 0
        let cooldown = max(policy.cooldownSeconds, providerHint)
        let openUntil = nowProvider().addingTimeInterval(cooldown)
        circuitOpenUntil = openUntil

        logger.warning("Provider circuit breaker opened after repeated 429s.", metadata: [
            "requestTraceID": "\(requestTraceID)",
            "consecutive429": "\(consecutiveRateLimitFailures)",
            "cooldownSeconds": "\(String(format: "%.1f", cooldown))",
            "model": "\(model)"
        ])
    }

    private func applyRequestThrottleIfNeeded(requestTraceID: String) async throws {
        guard let limit = requestsPerMinuteLimit, limit > 0 else { return }

        let now = nowProvider()
        let windowStart = now.addingTimeInterval(-60)
        requestTimestamps = requestTimestamps.filter { $0 >= windowStart }

        let rateWindowDelay = Self.throttleDelaySeconds(
            now: now,
            recentRequests: requestTimestamps,
            limitPerMinute: limit
        )
        let spacingDelay = Self.spacingDelaySeconds(
            now: now,
            recentRequests: requestTimestamps,
            limitPerMinute: limit
        )
        let delay = max(rateWindowDelay, spacingDelay)
        if delay > 0 {
            logger.warning("Provider request throttle engaged.", metadata: [
                "requestTraceID": "\(requestTraceID)",
                "delaySeconds": "\(String(format: "%.2f", delay))",
                "windowDelaySeconds": "\(String(format: "%.2f", rateWindowDelay))",
                "spacingDelaySeconds": "\(String(format: "%.2f", spacingDelay))",
                "rpmLimit": "\(limit)",
                "model": "\(model)"
            ])
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let afterSleepWindowStart = nowProvider().addingTimeInterval(-60)
            requestTimestamps = requestTimestamps.filter { $0 >= afterSleepWindowStart }
        }

        requestTimestamps.append(nowProvider())
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

    nonisolated static func containsPseudoToolSyntax(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"`{3}\s*tool"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed.range(of: #"`{3}\s*functions?(?:\.[\w.-]+)?(?::\d+)?\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed.range(of: #"<\s*function[_-]?calls\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed.range(of: #"<\s*invoke\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    nonisolated static func recoverPseudoToolCalls(from text: String) -> [InferenceResponse.ParsedToolCall] {
        var calls: [InferenceResponse.ParsedToolCall] = []

        if let regex = try? NSRegularExpression(
            pattern: #"<\s*invoke\s+name\s*=\s*"([^"]+)"\s*>([\s\S]*?)<\s*/\s*invoke\s*>"#,
            options: [.caseInsensitive]
        ) {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            for match in matches where match.numberOfRanges >= 3 {
                guard let nameRange = Range(match.range(at: 1), in: text),
                      let bodyRange = Range(match.range(at: 2), in: text) else {
                    continue
                }
                let rawName = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedName = normalizePseudoToolName(rawName)
                let body = String(text[bodyRange])
                let arguments = parseInvokeParameters(body)
                calls.append(
                    InferenceResponse.ParsedToolCall(
                        id: "pseudo-\(UUID().uuidString)",
                        name: normalizedName,
                        arguments: arguments
                    )
                )
            }
        }

        if !calls.isEmpty {
            return calls
        }

        if let regex = try? NSRegularExpression(
            pattern: #"`{3}\s*tool\s*[\r\n]+([a-zA-Z0-9_-]+)\s*[\r\n]+([\s\S]*?)`{3}"#,
            options: [.caseInsensitive]
        ) {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            for match in matches where match.numberOfRanges >= 3 {
                guard let nameRange = Range(match.range(at: 1), in: text),
                      let argsRange = Range(match.range(at: 2), in: text) else {
                    continue
                }
                let rawName = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedName = normalizePseudoToolName(rawName)
                let rawArgs = String(text[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let arguments = parseJSONObjectArguments(rawArgs)
                calls.append(
                    InferenceResponse.ParsedToolCall(
                        id: "pseudo-\(UUID().uuidString)",
                        name: normalizedName,
                        arguments: arguments
                    )
                )
            }
        }

        if calls.isEmpty,
           let regex = try? NSRegularExpression(
               pattern: #"`{3}\s*functions?(?:\.([a-zA-Z0-9_.-]+))?(?::\d+)?\s*[\r\n]+([\s\S]*?)`{3}"#,
               options: [.caseInsensitive]
           ) {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            for match in matches where match.numberOfRanges >= 3 {
                let capturedName: String? = {
                    guard match.range(at: 1).location != NSNotFound,
                          let range = Range(match.range(at: 1), in: text) else {
                        return nil
                    }
                    return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                }()
                guard let payloadRange = Range(match.range(at: 2), in: text) else {
                    continue
                }
                let rawPayload = String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let name = normalizePseudoToolName(capturedName ?? "functions")
                let arguments = parseJSONObjectArguments(rawPayload)
                calls.append(
                    InferenceResponse.ParsedToolCall(
                        id: "pseudo-\(UUID().uuidString)",
                        name: name,
                        arguments: arguments
                    )
                )
            }
        }

        return calls
    }

    nonisolated private static func normalizePseudoToolName(_ name: String) -> String {
        let normalized = name.lowercased()
        switch normalized {
        case "search_web":
            return "web_search"
        case "fetch_web":
            return "web_fetch"
        case "send_message":
            return "send_message"
        case let value where value.hasSuffix("__web_search"):
            return "web_search"
        case let value where value.hasSuffix("__web_fetch"):
            return "web_fetch"
        case let value where value.hasSuffix("__send_message"):
            return "send_message"
        default:
            return name
        }
    }

    nonisolated private static func parseInvokeParameters(_ body: String) -> [String: SendableValue] {
        var parsed: [String: SendableValue] = [:]
        guard let regex = try? NSRegularExpression(
            pattern: #"<\s*parameter\s+name\s*=\s*"([^"]+)"\s*>([\s\S]*?)<\s*/\s*parameter\s*>"#,
            options: [.caseInsensitive]
        ) else {
            return parsed
        }
        let nsRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = regex.matches(in: body, options: [], range: nsRange)
        for match in matches where match.numberOfRanges >= 3 {
            guard let keyRange = Range(match.range(at: 1), in: body),
                  let valueRange = Range(match.range(at: 2), in: body) else {
                continue
            }
            let key = String(body[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(body[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                continue
            }
            if let jsonValue = parseJSONValue(rawValue) {
                parsed[key] = jsonValue
            } else {
                parsed[key] = .string(rawValue)
            }
        }
        return parsed
    }

    nonisolated private static func parseJSONObjectArguments(_ raw: String) -> [String: SendableValue] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var parsed: [String: SendableValue] = [:]
        for (key, value) in json {
            if let converted = convertPseudoSendableValue(value) {
                parsed[key] = converted
            }
        }
        return parsed
    }

    nonisolated private static func parseJSONValue(_ raw: String) -> SendableValue? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return convertPseudoSendableValue(object)
    }

    nonisolated private static func convertPseudoSendableValue(_ value: Any) -> SendableValue? {
        if value is NSNull { return .null }
        if let str = value as? String { return .string(str) }
        if let bool = value as? Bool { return .bool(bool) }
        if let num = value as? NSNumber {
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
            return .array(array.compactMap(convertPseudoSendableValue))
        }
        if let dictionary = value as? [String: Any] {
            var converted: [String: SendableValue] = [:]
            for (key, item) in dictionary {
                if let sendable = convertPseudoSendableValue(item) {
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
        var request = URLRequest(url: Self.chatCompletionsURL(baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Use max_completion_tokens for GPT-5.2+ models, max_tokens for older models
        let maxTokensKey = model.hasPrefix("gpt-5") ? "max_completion_tokens" : "max_tokens"
        
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": requestTemperature(from: options.temperature),
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
            if let forcedTool = Self.forcedToolChoice(
                fromMessages: messages,
                tools: tools,
                environment: ProcessInfo.processInfo.environment
            ),
               Self.supportsForcedToolChoice(
                model: model,
                host: baseURL.host ?? ""
               ) {
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

    private func requestTemperature(from requested: Double) -> Double {
        // Moonshot/Kimi endpoints can reject non-1 values for temperature on some models.
        // Force compatibility here to avoid request failures.
        let host = (baseURL.host ?? "").lowercased()
        if model.lowercased().hasPrefix("kimi") || host.contains("moonshot") {
            return 1.0
        }
        return requested
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

actor ProviderRequestDiagnostics {
    private var fallbackEvents: [OpenAICompatibleProvider.FallbackEvent] = []

    func recordFallback(reason: String) {
        fallbackEvents.append(.init(reason: reason))
    }

    func metadata() -> [String: SendableValue] {
        guard !fallbackEvents.isEmpty else { return [:] }
        let reasons = fallbackEvents.map(\.reason)
        return [
            "nanoclaw.provider_fallback_used": .bool(true),
            "nanoclaw.provider_fallback_count": .int(fallbackEvents.count),
            "nanoclaw.provider_fallback_reasons": .array(reasons.map { .string($0) }),
            "nanoclaw.provider_fallback_reason": .string(reasons.last ?? "unknown")
        ]
    }
}

enum ProviderRequestDiagnosticsContext {
    @TaskLocal static var current: ProviderRequestDiagnostics?
}
