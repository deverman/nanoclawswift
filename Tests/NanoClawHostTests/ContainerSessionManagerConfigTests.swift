import Foundation
import Testing

@testable import NanoClawHost

@Test
func testContainerSessionManagerDoesNotPassSecretKeysToContainerEnv() {
    #expect(ContainerSessionManager.shouldPassEnvironmentKeyToContainer("MODEL_PROVIDER"))
    #expect(ContainerSessionManager.shouldPassEnvironmentKeyToContainer("BASE_URL"))
    #expect(!ContainerSessionManager.shouldPassEnvironmentKeyToContainer("OPENAI_API_KEY"))
    #expect(!ContainerSessionManager.shouldPassEnvironmentKeyToContainer("MOONSHOT_API_KEY"))
    #expect(!ContainerSessionManager.shouldPassEnvironmentKeyToContainer("ANTHROPIC_API_KEY"))
    #expect(!ContainerSessionManager.shouldPassEnvironmentKeyToContainer("NANOCLAW_FALLBACK_API_KEY"))
}

@Test
func testContainerSessionManagerBuildsAgentConfigPayloadWithPrimaryAndFallbackSecrets() {
    let payload = ContainerSessionManager.agentConfigFilePayload(
        passthroughEnvironment: [
            "MODEL_PROVIDER": "kimi",
            "MODEL_NAME": "kimi-k2.5",
            "MOONSHOT_API_KEY": "primary-kimi-key",
            "OPENAI_API_KEY": "openai-key",
            "BASE_URL": "http://192.168.64.1:18081/relay/kimi/v1",
            "ASSISTANT_NAME": "Andy",
            "NANOCLAW_FALLBACK_PROVIDER": "openai",
            "NANOCLAW_FALLBACK_MODEL": "gpt-4.1-mini",
            "NANOCLAW_FALLBACK_BASE_URL": "http://192.168.64.1:18081/relay/openai/v1",
            "NANOCLAW_FALLBACK_RPM_LIMIT": "3"
        ],
        containerTimeoutMs: 300_000
    )

    #expect(payload.api_key == "primary-kimi-key")
    #expect(payload.model_provider == "kimi")
    #expect(payload.model_name == "kimi-k2.5")
    #expect(payload.base_url == "http://192.168.64.1:18081/relay/kimi/v1")
    #expect(payload.assistant_name == "Andy")
    #expect(payload.fallback_provider == "openai")
    #expect(payload.fallback_model == "gpt-4.1-mini")
    #expect(payload.fallback_base_url == "http://192.168.64.1:18081/relay/openai/v1")
    #expect(payload.fallback_api_key == "openai-key")
    #expect(payload.fallback_rpm_limit == "3")
    #expect(payload.timeout == 180)
}

@Test
func testContainerSessionManagerInfersFallbackIntoAgentConfigPayload() {
    let payload = ContainerSessionManager.agentConfigFilePayload(
        passthroughEnvironment: [
            "MODEL_PROVIDER": "kimi",
            "MODEL_NAME": "kimi-k2.5",
            "MOONSHOT_API_KEY": "primary-kimi-key",
            "OPENAI_API_KEY": "openai-key"
        ],
        containerTimeoutMs: 300_000
    )

    #expect(payload.api_key == "primary-kimi-key")
    #expect(payload.fallback_provider == "openai")
    #expect(payload.fallback_api_key == "openai-key")
}
