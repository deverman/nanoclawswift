import Foundation
import SwiftAgents
import Configuration

public struct LoopBudgetPolicy: Sendable, Equatable {
    public let maxIterations: Int
    public let timeout: Duration
    public let maxToolCalls: Int

    public init(maxIterations: Int, timeout: Duration, maxToolCalls: Int) {
        precondition(maxIterations > 0, "maxIterations must be positive")
        precondition(timeout > .zero, "timeout must be positive")
        precondition(maxToolCalls > 0, "maxToolCalls must be positive")
        self.maxIterations = maxIterations
        self.timeout = timeout
        self.maxToolCalls = maxToolCalls
    }
}

public struct ExecutionRetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let initialBackoffMs: Int
    public let maxBackoffMs: Int

    public init(maxAttempts: Int, initialBackoffMs: Int, maxBackoffMs: Int) {
        precondition(maxAttempts > 0, "maxAttempts must be positive")
        precondition(initialBackoffMs > 0, "initialBackoffMs must be positive")
        precondition(maxBackoffMs >= initialBackoffMs, "maxBackoffMs must be >= initialBackoffMs")
        self.maxAttempts = maxAttempts
        self.initialBackoffMs = initialBackoffMs
        self.maxBackoffMs = maxBackoffMs
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        let exponent = max(0, attempt - 1)
        let scaled = Int64(initialBackoffMs) << min(exponent, 20)
        let clamped = min(Int64(maxBackoffMs), scaled)
        return .milliseconds(clamped)
    }
}

public enum ExecutionRetryDecision: Sendable, Equatable {
    case retry(after: Duration)
    case fail
}

extension NanoClawAgent {
    private nonisolated static func intSetting(_ key: String, default defaultValue: Int) -> Int {
        if #available(macOS 15.0, iOS 18.0, *) {
            let reader = ConfigReader(
                provider: EnvironmentVariablesProvider(
                    environmentVariables: ProcessInfo.processInfo.environment
                )
            )
            return reader.int(forKey: ConfigKey(key), default: defaultValue)
        }
        return Int(ProcessInfo.processInfo.environment[key] ?? "") ?? defaultValue
    }

    private nonisolated static func boundedSetting(
        _ key: String,
        default defaultValue: Int,
        min: Int,
        max: Int
    ) -> Int {
        let value = intSetting(key, default: defaultValue)
        return Swift.max(min, Swift.min(max, value))
    }

    nonisolated static var toolRouteMaxIterations: Int {
        boundedSetting("NANOCLAW_TOOL_ROUTE_MAX_ITERATIONS", default: 16, min: 1, max: 60)
    }

    nonisolated static var planRouteMaxIterations: Int {
        boundedSetting("NANOCLAW_PLAN_ROUTE_MAX_ITERATIONS", default: 40, min: 1, max: 60)
    }

    nonisolated static var toolRouteMaxToolCalls: Int {
        boundedSetting("NANOCLAW_TOOL_ROUTE_MAX_TOOL_CALLS", default: 16, min: 1, max: 120)
    }

    nonisolated static var planRouteMaxToolCalls: Int {
        boundedSetting("NANOCLAW_PLAN_ROUTE_MAX_TOOL_CALLS", default: 40, min: 1, max: 200)
    }

    nonisolated static var scheduledToolRouteMaxToolCalls: Int {
        boundedSetting("NANOCLAW_SCHEDULED_TOOL_ROUTE_MAX_TOOL_CALLS", default: 24, min: 1, max: 120)
    }

    nonisolated static var scheduledPlanRouteMaxToolCalls: Int {
        boundedSetting("NANOCLAW_SCHEDULED_PLAN_ROUTE_MAX_TOOL_CALLS", default: 60, min: 1, max: 200)
    }

    nonisolated static var sessionCompactionThreshold: Int {
        boundedSetting("NANOCLAW_SESSION_COMPACTION_THRESHOLD", default: 40, min: 10, max: 200)
    }

    nonisolated static var sessionCompactionRetainCount: Int {
        let retain = boundedSetting("NANOCLAW_SESSION_COMPACTION_RETAIN", default: 20, min: 5, max: 120)
        return Swift.min(retain, sessionCompactionThreshold - 1)
    }

    nonisolated static var emptyVisibleReplyRetryDelayMs: Int {
        boundedSetting("NANOCLAW_EMPTY_VISIBLE_RETRY_DELAY_MS", default: 250, min: 50, max: 2_000)
    }

    nonisolated public static func loopBudgetPolicy(
        for route: ExecutionRoute,
        timeoutSeconds: Int,
        isScheduledTask: Bool = false
    ) -> LoopBudgetPolicy {
        let boundedTimeout = max(1, timeoutSeconds)
        switch route {
        case .toolCalling:
            return LoopBudgetPolicy(
                maxIterations: toolRouteMaxIterations,
                timeout: .seconds(boundedTimeout),
                maxToolCalls: isScheduledTask ? scheduledToolRouteMaxToolCalls : toolRouteMaxToolCalls
            )
        case .planAndExecute:
            return LoopBudgetPolicy(
                maxIterations: planRouteMaxIterations,
                timeout: .seconds(boundedTimeout),
                maxToolCalls: isScheduledTask ? scheduledPlanRouteMaxToolCalls : planRouteMaxToolCalls
            )
        }
    }

    nonisolated public static func retryPolicy(for route: ExecutionRoute) -> ExecutionRetryPolicy {
        switch route {
        case .toolCalling:
            return ExecutionRetryPolicy(maxAttempts: 2, initialBackoffMs: 250, maxBackoffMs: 1_000)
        case .planAndExecute:
            return ExecutionRetryPolicy(maxAttempts: 3, initialBackoffMs: 400, maxBackoffMs: 2_000)
        }
    }

    nonisolated public static func enforceLoopBudget(_ result: AgentResult, budget: LoopBudgetPolicy) throws {
        if result.iterationCount > budget.maxIterations {
            throw AgentError.maxIterationsExceeded(iterations: result.iterationCount)
        }
        if result.toolCalls.count > budget.maxToolCalls {
            throw AgentError.internalError(
                reason: "tool call budget exceeded (limit=\(budget.maxToolCalls), actual=\(result.toolCalls.count))"
            )
        }
        if result.duration > budget.timeout {
            throw AgentError.timeout(duration: budget.timeout)
        }
    }

    nonisolated public static func retryDecision(
        for error: Error,
        attempt: Int,
        policy: ExecutionRetryPolicy
    ) -> ExecutionRetryDecision {
        guard attempt < policy.maxAttempts else {
            return .fail
        }
        guard shouldRetry(error: error) else {
            return .fail
        }
        return .retry(after: policy.delay(forAttempt: attempt))
    }

    nonisolated static func shouldRetry(error: Error) -> Bool {
        if error is GuardrailError {
            return false
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .internationalRoamingOff,
                 .dataNotAllowed,
                 .callIsActive:
                return true
            default:
                return false
            }
        }

        if let agentError = error as? AgentError {
            switch agentError {
            case .rateLimitExceeded,
                 .inferenceProviderUnavailable:
                return true
            case let .generationFailed(reason):
                return isTransientGenerationFailure(reason)
            case .timeout,
                 .maxIterationsExceeded,
                 .invalidInput,
                 .toolNotFound,
                 .toolExecutionFailed,
                 .invalidToolArguments,
                 .contextWindowExceeded,
                 .guardrailViolation,
                 .contentFiltered,
                 .unsupportedLanguage,
                 .modelNotAvailable,
                 .embeddingFailed,
                 .internalError,
                 .cancelled:
                return false
            }
        }

        return false
    }

    nonisolated static func isTransientGenerationFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        let transientMarkers = [
            "429",
            "503",
            "rate limit",
            "temporarily unavailable",
            "timeout",
            "connection reset",
            "network"
        ]
        return transientMarkers.contains { normalized.contains($0) }
    }

    nonisolated static func timeoutSeconds(from timeout: Duration) -> Int {
        let seconds = timeout.components.seconds
        if seconds <= 0 {
            return 1
        }
        return Int(seconds)
    }
}
