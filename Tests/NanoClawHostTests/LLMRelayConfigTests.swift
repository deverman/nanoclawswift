import Foundation
import Testing

@testable import NanoClawHost

@Test
func testLLMRelayDefaultsAndAutoInjection() {
    let passthrough: [String: String] = [
        "MODEL_PROVIDER": "kimi",
        "MOONSHOT_API_KEY": "sk-test"
    ]

    let settings = LLMRelaySettings(
        mode: .auto,
        bindHost: "0.0.0.0",
        advertiseHost: "192.168.64.1",
        port: 18081
    )

    let updated = LLMRelayConfig.applyRelayBaseURLIfNeeded(
        passthrough: passthrough,
        settings: settings
    )

    #expect(updated["BASE_URL"] == "http://192.168.64.1:18081/relay/kimi/v1")
}

@Test
func testLLMRelayAutoModeRespectsExistingBaseURL() {
    let passthrough: [String: String] = [
        "MODEL_PROVIDER": "openai",
        "OPENAI_API_KEY": "sk-test",
        "BASE_URL": "https://custom.example/v1"
    ]

    let settings = LLMRelaySettings(
        mode: .auto,
        bindHost: "0.0.0.0",
        advertiseHost: "192.168.64.1",
        port: 18081
    )

    let updated = LLMRelayConfig.applyRelayBaseURLIfNeeded(
        passthrough: passthrough,
        settings: settings
    )

    #expect(updated["BASE_URL"] == "https://custom.example/v1")
}

@Test
func testLLMRelayForceModeOverridesExistingBaseURL() {
    let passthrough: [String: String] = [
        "MODEL_PROVIDER": "openai",
        "OPENAI_API_KEY": "sk-test",
        "BASE_URL": "https://custom.example/v1"
    ]

    let settings = LLMRelaySettings(
        mode: .force,
        bindHost: "0.0.0.0",
        advertiseHost: "192.168.64.1",
        port: 18081
    )

    let updated = LLMRelayConfig.applyRelayBaseURLIfNeeded(
        passthrough: passthrough,
        settings: settings
    )

    #expect(updated["BASE_URL"] == "http://192.168.64.1:18081/relay/openai/v1")
}

@Test
func testLLMRelayAutoModeInjectsFallbackBaseURLWhenUpstreamFallbackConfigured() {
    let passthrough: [String: String] = [
        "MODEL_PROVIDER": "openai",
        "OPENAI_API_KEY": "sk-test",
        "NANOCLAW_FALLBACK_PROVIDER": "kimi",
        "NANOCLAW_FALLBACK_BASE_URL": "https://api.moonshot.ai/v1"
    ]

    let settings = LLMRelaySettings(
        mode: .auto,
        bindHost: "0.0.0.0",
        advertiseHost: "192.168.64.1",
        port: 18081
    )

    let updated = LLMRelayConfig.applyRelayBaseURLIfNeeded(
        passthrough: passthrough,
        settings: settings
    )

    #expect(updated["NANOCLAW_FALLBACK_BASE_URL"] == "http://192.168.64.1:18081/relay/kimi/v1")
}

@Test
func testLLMRelayAutoModeKeepsCustomFallbackBaseURL() {
    let passthrough: [String: String] = [
        "MODEL_PROVIDER": "openai",
        "OPENAI_API_KEY": "sk-test",
        "NANOCLAW_FALLBACK_PROVIDER": "openai",
        "NANOCLAW_FALLBACK_BASE_URL": "https://custom.example/v1"
    ]

    let settings = LLMRelaySettings(
        mode: .auto,
        bindHost: "0.0.0.0",
        advertiseHost: "192.168.64.1",
        port: 18081
    )

    let updated = LLMRelayConfig.applyRelayBaseURLIfNeeded(
        passthrough: passthrough,
        settings: settings
    )

    #expect(updated["NANOCLAW_FALLBACK_BASE_URL"] == "https://custom.example/v1")
}

@Test
func testLLMRelayForceModeOverridesFallbackBaseURL() {
    let passthrough: [String: String] = [
        "MODEL_PROVIDER": "openai",
        "OPENAI_API_KEY": "sk-test",
        "NANOCLAW_FALLBACK_PROVIDER": "anthropic",
        "NANOCLAW_FALLBACK_BASE_URL": "https://custom.example/v1"
    ]

    let settings = LLMRelaySettings(
        mode: .force,
        bindHost: "0.0.0.0",
        advertiseHost: "192.168.64.1",
        port: 18081
    )

    let updated = LLMRelayConfig.applyRelayBaseURLIfNeeded(
        passthrough: passthrough,
        settings: settings
    )

    #expect(updated["NANOCLAW_FALLBACK_BASE_URL"] == "http://192.168.64.1:18081/relay/anthropic/v1")
}

@Test
func testLLMRelayRouteResolvesUpstreamURLAndProvider() throws {
    let resolved = try #require(
        LLMRelayConfig.resolveRelayRoute(path: "/relay/kimi/v1/chat/completions")
    )

    #expect(resolved.provider == .kimi)
    #expect(resolved.upstreamURL.absoluteString == "https://api.moonshot.ai/v1/chat/completions")
}

@Test
func testLLMRelayRouteRejectsInvalidPrefix() {
    let resolved = LLMRelayConfig.resolveRelayRoute(path: "/v1/chat/completions")
    #expect(resolved == nil)
}
