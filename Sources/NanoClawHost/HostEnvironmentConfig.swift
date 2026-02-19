import Configuration
import Foundation
import Logging

struct HostEnvironmentConfig {
    static let containerPassthroughKeys: [String] = [
        "MODEL_PROVIDER",
        "MODEL_NAME",
        "OPENAI_API_KEY",
        "MOONSHOT_API_KEY",
        "ANTHROPIC_API_KEY",
        "BASE_URL",
        "TIMEOUT",
        "MAX_TOKENS",
        "ASSISTANT_NAME",
        "NANOCLAW_PROVIDER_RPM_LIMIT",
        "KIMI_RPM_LIMIT",
        "NANOCLAW_FALLBACK_PROVIDER",
        "NANOCLAW_FALLBACK_MODEL",
        "NANOCLAW_FALLBACK_BASE_URL",
        "NANOCLAW_FALLBACK_API_KEY",
        "NANOCLAW_FALLBACK_RPM_LIMIT",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "NANOCLAW_WEB_BROKER_URL",
        "NANOCLAW_FOCUSRELAY_BROKER_URL",
        "NANOCLAW_MCP_HOST_BROKER_URL",
    ]

    let containerImage: String
    let containerTimeoutMs: Int
    let maxConcurrentGroups: Int
    let logLevel: Logger.Level?

    let assistantName: String
    let telegramBotToken: String
    let telegramOwnerIDRaw: String
    let telegramOwnerID: Int64?
    let telegramPollLimit: Int
    let telegramPollTimeoutSec: Int
    let telegramOutboundPollMs: Int
    let telegramOutboundBatchSize: Int
    let prewarmEnabled: Bool
    let prewarmLimit: Int
    let workingAckEnabled: Bool
    let workingAckThresholdMs: Int
    let workingAckRepeatIntervalMs: Int
    let latencyWindowSize: Int
    let latencySLOP50Ms: Int
    let latencySLOP95Ms: Int
    let timeoutAlertRate: Double
    let retryAlertRate: Double
    let sessionJanitorIntervalSec: Int
    let queueJobWatchdogMs: Int
    let staleClaimReapAgeSec: Int
    let scheduledRetryMaxAttempts: Int
    let scheduledRetryInitialBackoffSec: Int
    let scheduledRetryMaxBackoffSec: Int
    let telegramTypingIntervalMs: Int
    let telegramTypingStartDelayMs: Int
    let llmRelayMode: LLMRelayMode
    let llmRelayBindHost: String
    let llmRelayAdvertiseHost: String
    let llmRelayPort: Int
    let focusRelayEnabled: Bool
    let focusRelayCommand: String
    let schedulerTimeZone: TimeZone
    let containerPassthroughEnvironment: [String: String]

    var hasInvalidTelegramOwnerID: Bool {
        !telegramOwnerIDRaw.isEmpty && telegramOwnerID == nil
    }

    static func load(from environment: [String: String] = ProcessInfo.processInfo.environment) -> HostEnvironmentConfig {
        if #available(macOS 15.0, iOS 18.0, *) {
            let reader = ConfigReader(
                provider: EnvironmentVariablesProvider(environmentVariables: environment)
            )
            return makeConfig(
                environment: environment,
                string: { key, defaultValue in
                    reader.string(forKey: ConfigKey(key), default: defaultValue)
                },
                int: { key, defaultValue in
                    reader.int(forKey: ConfigKey(key), default: defaultValue)
                },
                double: { key, defaultValue in
                    reader.double(forKey: ConfigKey(key), default: defaultValue)
                }
            )
        }

        return makeConfig(
            environment: environment,
            string: { key, defaultValue in
                environment[key] ?? defaultValue
            },
            int: { key, defaultValue in
                Int(environment[key] ?? "") ?? defaultValue
            },
            double: { key, defaultValue in
                Double(environment[key] ?? "") ?? defaultValue
            }
        )
    }

    private static func makeConfig(
        environment: [String: String],
        string: (String, String) -> String,
        int: (String, Int) -> Int,
        double: (String, Double) -> Double
    ) -> HostEnvironmentConfig {
        let telegramOwnerIDRaw = string("TELEGRAM_OWNER_ID", "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutAlertRate = parseRate(
            double("NANOCLAW_TIMEOUT_ALERT_RATE", 0.05),
            fallback: 0.05
        )
        let retryAlertRate = parseRate(
            double("NANOCLAW_RETRY_ALERT_RATE", 0.02),
            fallback: 0.02
        )
        let timeZone: TimeZone = {
            let identifier = string("TZ", "")
            guard !identifier.isEmpty, let parsed = TimeZone(identifier: identifier) else {
                return .current
            }
            return parsed
        }()
        var passthrough: [String: String] = [:]
        for key in containerPassthroughKeys {
            if let value = environment[key], !value.isEmpty {
                passthrough[key] = value
            }
        }

        return HostEnvironmentConfig(
            containerImage: string("CONTAINER_IMAGE", "nanoclawswift-agent:slim"),
            containerTimeoutMs: int("CONTAINER_TIMEOUT", 300000),
            maxConcurrentGroups: int("NANOCLAW_MAX_CONCURRENCY", 2),
            logLevel: Logger.Level(rawValue: string("NANOCLAW_LOG_LEVEL", "").lowercased()),
            assistantName: string("ASSISTANT_NAME", "Andy"),
            telegramBotToken: string("TELEGRAM_BOT_TOKEN", "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            telegramOwnerIDRaw: telegramOwnerIDRaw,
            telegramOwnerID: Int64(telegramOwnerIDRaw),
            telegramPollLimit: int("NANOCLAW_TELEGRAM_POLL_LIMIT", 50),
            telegramPollTimeoutSec: int("NANOCLAW_TELEGRAM_POLL_TIMEOUT_SEC", 25),
            telegramOutboundPollMs: int("NANOCLAW_TELEGRAM_OUTBOUND_POLL_MS", 1000),
            telegramOutboundBatchSize: int("NANOCLAW_TELEGRAM_OUTBOUND_BATCH_SIZE", 10),
            prewarmEnabled: parseEnabled(string("NANOCLAW_PREWARM_GROUP_SESSIONS", "")),
            prewarmLimit: int("NANOCLAW_PREWARM_LIMIT", 3),
            workingAckEnabled: parseEnabled(string("NANOCLAW_WORKING_ACK_ENABLED", "")),
            workingAckThresholdMs: int("NANOCLAW_WORKING_ACK_THRESHOLD_MS", 8000),
            workingAckRepeatIntervalMs: int("NANOCLAW_WORKING_ACK_REPEAT_INTERVAL_MS", 30000),
            latencyWindowSize: int("NANOCLAW_LATENCY_WINDOW_SIZE", 200),
            latencySLOP50Ms: int("NANOCLAW_LATENCY_SLO_P50_MS", 15000),
            latencySLOP95Ms: int("NANOCLAW_LATENCY_SLO_P95_MS", 60000),
            timeoutAlertRate: timeoutAlertRate,
            retryAlertRate: retryAlertRate,
            sessionJanitorIntervalSec: int("NANOCLAW_SESSION_JANITOR_INTERVAL_SEC", 30),
            queueJobWatchdogMs: int("NANOCLAW_QUEUE_JOB_WATCHDOG_MS", 295000),
            staleClaimReapAgeSec: int("NANOCLAW_STALE_CLAIM_REAP_AGE_SEC", 180),
            scheduledRetryMaxAttempts: int("NANOCLAW_SCHEDULED_RETRY_MAX_ATTEMPTS", 2),
            scheduledRetryInitialBackoffSec: int("NANOCLAW_SCHEDULED_RETRY_INITIAL_BACKOFF_SEC", 30),
            scheduledRetryMaxBackoffSec: int("NANOCLAW_SCHEDULED_RETRY_MAX_BACKOFF_SEC", 300),
            telegramTypingIntervalMs: int("NANOCLAW_TELEGRAM_TYPING_INTERVAL_MS", 4000),
            telegramTypingStartDelayMs: int("NANOCLAW_TELEGRAM_TYPING_START_DELAY_MS", 1500),
            llmRelayMode: LLMRelayMode.parse(string("NANOCLAW_LLM_RELAY_MODE", "auto")),
            llmRelayBindHost: string("NANOCLAW_LLM_RELAY_BIND", "0.0.0.0"),
            llmRelayAdvertiseHost: string("NANOCLAW_LLM_RELAY_HOST", "192.168.64.1"),
            llmRelayPort: int("NANOCLAW_LLM_RELAY_PORT", 18081),
            focusRelayEnabled: parseEnabled(string("NANOCLAW_FOCUSRELAY_ENABLED", "")),
            focusRelayCommand: string("NANOCLAW_FOCUSRELAY_COMMAND", "/opt/homebrew/bin/focusrelay")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            schedulerTimeZone: timeZone,
            containerPassthroughEnvironment: passthrough
        )
    }

    private static func parseEnabled(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return !(lowered == "0" || lowered == "false" || lowered == "no")
    }

    private static func parseRate(_ parsed: Double, fallback: Double) -> Double {
        guard parsed >= 0 else { return fallback }
        return min(parsed, 1.0)
    }
}
