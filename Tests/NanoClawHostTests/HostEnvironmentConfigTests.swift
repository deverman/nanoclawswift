import Foundation
import Testing
import Logging

@testable import NanoClawHost

@Test
func testHostEnvironmentConfigLoadsTelegramTokenAndOwnerID() {
    let config = HostEnvironmentConfig.load(
        from: [
            "TELEGRAM_BOT_TOKEN": "  test-token  ",
            "TELEGRAM_OWNER_ID": " 123456 ",
            "ASSISTANT_NAME": "Claw",
            "NANOCLAW_TELEGRAM_POLL_LIMIT": "30",
            "NANOCLAW_TELEGRAM_POLL_TIMEOUT_SEC": "10",
        ]
    )

    #expect(config.telegramBotToken == "test-token")
    #expect(config.telegramOwnerIDRaw == "123456")
    #expect(config.telegramOwnerID == 123456)
    #expect(config.hasInvalidTelegramOwnerID == false)
    #expect(config.assistantName == "Claw")
    #expect(config.telegramPollLimit == 30)
    #expect(config.telegramPollTimeoutSec == 10)
}

@Test
func testHostEnvironmentConfigTreatsInvalidOwnerAsNilButFlagged() {
    let config = HostEnvironmentConfig.load(
        from: [
            "TELEGRAM_BOT_TOKEN": "token",
            "TELEGRAM_OWNER_ID": "abc",
        ]
    )

    #expect(config.telegramBotToken == "token")
    #expect(config.telegramOwnerIDRaw == "abc")
    #expect(config.telegramOwnerID == nil)
    #expect(config.hasInvalidTelegramOwnerID == true)
}

@Test
func testHostEnvironmentConfigUsesDefaultsWhenUnsetOrInvalid() {
    let config = HostEnvironmentConfig.load(
        from: [
            "NANOCLAW_TELEGRAM_POLL_LIMIT": "invalid",
            "NANOCLAW_TELEGRAM_POLL_TIMEOUT_SEC": "bad",
        ]
    )

    #expect(config.assistantName == "Andy")
    #expect(config.telegramBotToken == "")
    #expect(config.telegramOwnerIDRaw == "")
    #expect(config.telegramOwnerID == nil)
    #expect(config.hasInvalidTelegramOwnerID == false)
    #expect(config.telegramPollLimit == 50)
    #expect(config.telegramPollTimeoutSec == 25)
    #expect(config.containerImage == "nanoclawswift-agent:slim")
    #expect(config.containerTimeoutMs == 300000)
    #expect(config.maxConcurrentGroups == 2)
    #expect(config.logLevel == nil)
    #expect(config.telegramOutboundPollMs == 1000)
    #expect(config.telegramOutboundBatchSize == 10)
    #expect(config.prewarmEnabled == true)
    #expect(config.prewarmLimit == 3)
    #expect(config.workingAckEnabled == true)
    #expect(config.workingAckThresholdMs == 8000)
    #expect(config.workingAckRepeatIntervalMs == 30000)
    #expect(config.latencyWindowSize == 200)
    #expect(config.latencySLOP50Ms == 15000)
    #expect(config.latencySLOP95Ms == 60000)
    #expect(config.timeoutAlertRate == 0.05)
    #expect(config.retryAlertRate == 0.02)
    #expect(config.sessionJanitorIntervalSec == 30)
    #expect(config.queueJobWatchdogMs == 295000)
    #expect(config.staleClaimReapAgeSec == 180)
    #expect(config.scheduledRetryMaxAttempts == 2)
    #expect(config.scheduledRetryInitialBackoffSec == 30)
    #expect(config.scheduledRetryMaxBackoffSec == 300)
    #expect(config.telegramTypingIntervalMs == 4000)
    #expect(config.telegramTypingStartDelayMs == 1500)
    #expect(config.focusRelayEnabled == true)
    #expect(config.focusRelayCommand == "/opt/homebrew/bin/focusrelay")
}

@Test
func testHostEnvironmentConfigLoadsHostRuntimeServiceAndContainerPassthroughValues() {
    let config = HostEnvironmentConfig.load(
        from: [
            "CONTAINER_IMAGE": "custom-image:latest",
            "CONTAINER_TIMEOUT": "120000",
            "NANOCLAW_MAX_CONCURRENCY": "5",
            "NANOCLAW_LOG_LEVEL": "DEBUG",
            "NANOCLAW_TELEGRAM_OUTBOUND_POLL_MS": "250",
            "NANOCLAW_TELEGRAM_OUTBOUND_BATCH_SIZE": "9",
            "NANOCLAW_PREWARM_GROUP_SESSIONS": "false",
            "NANOCLAW_PREWARM_LIMIT": "11",
            "NANOCLAW_WORKING_ACK_ENABLED": "0",
            "NANOCLAW_WORKING_ACK_THRESHOLD_MS": "4200",
            "NANOCLAW_WORKING_ACK_REPEAT_INTERVAL_MS": "15000",
            "NANOCLAW_LATENCY_WINDOW_SIZE": "123",
            "NANOCLAW_LATENCY_SLO_P50_MS": "17000",
            "NANOCLAW_LATENCY_SLO_P95_MS": "92000",
            "NANOCLAW_TIMEOUT_ALERT_RATE": "0.4",
            "NANOCLAW_RETRY_ALERT_RATE": "0.15",
            "NANOCLAW_SESSION_JANITOR_INTERVAL_SEC": "45",
            "NANOCLAW_QUEUE_JOB_WATCHDOG_MS": "90000",
            "NANOCLAW_STALE_CLAIM_REAP_AGE_SEC": "240",
            "NANOCLAW_SCHEDULED_RETRY_MAX_ATTEMPTS": "4",
            "NANOCLAW_SCHEDULED_RETRY_INITIAL_BACKOFF_SEC": "12",
            "NANOCLAW_SCHEDULED_RETRY_MAX_BACKOFF_SEC": "144",
            "NANOCLAW_TELEGRAM_TYPING_INTERVAL_MS": "3500",
            "NANOCLAW_TELEGRAM_TYPING_START_DELAY_MS": "800",
            "TZ": "UTC",
            "MODEL_PROVIDER": "moonshot",
            "OPENAI_API_KEY": "abc123",
            "KIMI_RPM_LIMIT": "4",
            "NANOCLAW_PROVIDER_RPM_LIMIT": "6",
            "NANOCLAW_FALLBACK_PROVIDER": "openai",
            "NANOCLAW_FALLBACK_MODEL": "gpt-4o-mini",
            "NANOCLAW_FALLBACK_BASE_URL": "https://api.openai.com/v1",
            "NANOCLAW_FALLBACK_API_KEY": "fallback-key",
            "NANOCLAW_FALLBACK_RPM_LIMIT": "3",
            "NANOCLAW_WEB_BROKER_URL": "http://127.0.0.1:8080",
            "NANOCLAW_FOCUSRELAY_ENABLED": "false",
            "NANOCLAW_FOCUSRELAY_COMMAND": "/usr/local/bin/focusrelay",
            "NANOCLAW_FOCUSRELAY_BROKER_URL": "http://127.0.0.1:8080/focusrelay",
            "NANOCLAW_MCP_HOST_BROKER_URL": "http://127.0.0.1:8080/mcp/host",
        ]
    )

    #expect(config.containerImage == "custom-image:latest")
    #expect(config.containerTimeoutMs == 120000)
    #expect(config.maxConcurrentGroups == 5)
    #expect(config.logLevel == .debug)
    #expect(config.telegramOutboundPollMs == 250)
    #expect(config.telegramOutboundBatchSize == 9)
    #expect(config.prewarmEnabled == false)
    #expect(config.prewarmLimit == 11)
    #expect(config.workingAckEnabled == false)
    #expect(config.workingAckThresholdMs == 4200)
    #expect(config.workingAckRepeatIntervalMs == 15000)
    #expect(config.latencyWindowSize == 123)
    #expect(config.latencySLOP50Ms == 17000)
    #expect(config.latencySLOP95Ms == 92000)
    #expect(config.timeoutAlertRate == 0.4)
    #expect(config.retryAlertRate == 0.15)
    #expect(config.sessionJanitorIntervalSec == 45)
    #expect(config.queueJobWatchdogMs == 90000)
    #expect(config.staleClaimReapAgeSec == 240)
    #expect(config.scheduledRetryMaxAttempts == 4)
    #expect(config.scheduledRetryInitialBackoffSec == 12)
    #expect(config.scheduledRetryMaxBackoffSec == 144)
    #expect(config.telegramTypingIntervalMs == 3500)
    #expect(config.telegramTypingStartDelayMs == 800)
    #expect(config.focusRelayEnabled == false)
    #expect(config.focusRelayCommand == "/usr/local/bin/focusrelay")
    #expect(config.schedulerTimeZone.secondsFromGMT() == 0)
    #expect(config.containerPassthroughEnvironment["MODEL_PROVIDER"] == "moonshot")
    #expect(config.containerPassthroughEnvironment["OPENAI_API_KEY"] == "abc123")
    #expect(config.containerPassthroughEnvironment["KIMI_RPM_LIMIT"] == "4")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_PROVIDER_RPM_LIMIT"] == "6")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_FALLBACK_PROVIDER"] == "openai")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_FALLBACK_MODEL"] == "gpt-4o-mini")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_FALLBACK_BASE_URL"] == "https://api.openai.com/v1")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_FALLBACK_API_KEY"] == "fallback-key")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_FALLBACK_RPM_LIMIT"] == "3")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_WEB_BROKER_URL"] == "http://127.0.0.1:8080")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_FOCUSRELAY_BROKER_URL"] == "http://127.0.0.1:8080/focusrelay")
    #expect(config.containerPassthroughEnvironment["NANOCLAW_MCP_HOST_BROKER_URL"] == "http://127.0.0.1:8080/mcp/host")
}

@Test
func testHostEnvironmentConfigClampsRatesAndFallsBackForInvalidTimeZoneAndLogLevel() {
    let config = HostEnvironmentConfig.load(
        from: [
            "NANOCLAW_LOG_LEVEL": "INVALID",
            "NANOCLAW_TIMEOUT_ALERT_RATE": "-1",
            "NANOCLAW_RETRY_ALERT_RATE": "2.5",
            "TZ": "Not/A_Real_Timezone",
        ]
    )

    #expect(config.logLevel == nil)
    #expect(config.timeoutAlertRate == 0.05)
    #expect(config.retryAlertRate == 1.0)
    #expect(config.schedulerTimeZone.identifier == TimeZone.current.identifier)
}
