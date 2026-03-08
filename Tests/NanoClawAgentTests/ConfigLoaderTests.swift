import Testing
@testable import NanoClawAgent
import Foundation

@Test
func testConfigLoaderUsesOpenAIKey() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "OPENAI_API_KEY": "test-openai-key",
        "MODEL_PROVIDER": "openai",
        "MODEL_NAME": nil
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .openai)
        #expect(config.apiKey == "test-openai-key")
        #expect(config.model == .gpt52)
    }
}

@Test
func testConfigLoaderRespectsModelOverride() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "OPENAI_API_KEY": "test-openai-key",
        "MODEL_PROVIDER": "openai",
        "MODEL_NAME": "gpt-4o"
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .openai)
        #expect(config.model == .gpt4o)
    }
}

@Test
func testConfigLoaderRespectsGPT41MiniOverride() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "OPENAI_API_KEY": "test-openai-key",
        "MODEL_PROVIDER": "openai",
        "MODEL_NAME": "gpt-4.1-mini"
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .openai)
        #expect(config.model == .gpt41Mini)
    }
}

@Test
func testConfigLoaderUsesLongerDefaultTimeoutWhenUnset() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "OPENAI_API_KEY": "test-openai-key",
        "MODEL_PROVIDER": "openai",
        "TIMEOUT": nil
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.timeout == 180)
    }
}

@Test
func testConfigLoaderDefaultsKimiRPMTo8() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "MOONSHOT_API_KEY": "test-kimi-key",
        "MODEL_PROVIDER": "kimi",
        "KIMI_RPM_LIMIT": nil,
        "NANOCLAW_PROVIDER_RPM_LIMIT": nil
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .kimi)
        #expect(config.requestsPerMinuteLimit == 8)
    }
}

@Test
func testConfigLoaderUsesKimiRPMOverride() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "MOONSHOT_API_KEY": "test-kimi-key",
        "MODEL_PROVIDER": "kimi",
        "KIMI_RPM_LIMIT": "12"
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.requestsPerMinuteLimit == 12)
    }
}

@Test
func testConfigLoaderUsesGlobalProviderRPMOverride() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "OPENAI_API_KEY": "test-openai-key",
        "MODEL_PROVIDER": "openai",
        "NANOCLAW_PROVIDER_RPM_LIMIT": "7"
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .openai)
        #expect(config.requestsPerMinuteLimit == 7)
    }
}

@Test
func testConfigLoaderLoadsOpenAIFallbackForKimi() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "MOONSHOT_API_KEY": "test-kimi-key",
        "OPENAI_API_KEY": "test-openai-key",
        "MODEL_PROVIDER": "kimi",
        "NANOCLAW_FALLBACK_PROVIDER": "openai",
        "NANOCLAW_FALLBACK_MODEL": "gpt-4o-mini",
        "NANOCLAW_FALLBACK_BASE_URL": "https://api.openai.com/v1",
        "NANOCLAW_FALLBACK_RPM_LIMIT": "3"
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .kimi)
        #expect(config.fallbackProvider == .openai)
        #expect(config.fallbackAPIKey == "test-openai-key")
        #expect(config.fallbackModel == .gpt4oMini)
        #expect(config.fallbackBaseURL == "https://api.openai.com/v1")
        #expect(config.fallbackRequestsPerMinuteLimit == 3)
    }
}

@Test
func testConfigLoaderInfersOpenAIFallbackFromSecondaryKey() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "MOONSHOT_API_KEY": "test-kimi-key",
        "OPENAI_API_KEY": "test-openai-key",
        "MODEL_PROVIDER": "kimi",
        "NANOCLAW_FALLBACK_PROVIDER": nil,
        "NANOCLAW_FALLBACK_MODEL": nil,
        "NANOCLAW_FALLBACK_BASE_URL": nil,
        "NANOCLAW_FALLBACK_API_KEY": nil
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .kimi)
        #expect(config.fallbackProvider == .openai)
        #expect(config.fallbackAPIKey == "test-openai-key")
        #expect(config.fallbackModel == nil)
        #expect(config.fallbackBaseURL == nil)
    }
}

@Test
func testConfigLoaderPrefersExplicitFallbackProviderOverInference() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "MOONSHOT_API_KEY": "test-kimi-key",
        "OPENAI_API_KEY": "test-openai-key",
        "ANTHROPIC_API_KEY": "test-anthropic-key",
        "MODEL_PROVIDER": "kimi",
        "NANOCLAW_FALLBACK_PROVIDER": "anthropic",
        "NANOCLAW_FALLBACK_MODEL": nil,
        "NANOCLAW_FALLBACK_BASE_URL": nil,
        "NANOCLAW_FALLBACK_API_KEY": nil
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .kimi)
        #expect(config.fallbackProvider == .anthropic)
        #expect(config.fallbackAPIKey == "test-anthropic-key")
    }
}

@Test
func testConfigLoaderInheritsPrimaryBaseURLForSameProviderFallback() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "OPENAI_API_KEY": "test-openai-key",
        "MODEL_PROVIDER": "openai",
        "BASE_URL": "http://192.168.64.1:18081/relay/openai/v1",
        "NANOCLAW_FALLBACK_PROVIDER": "openai",
        "NANOCLAW_FALLBACK_BASE_URL": nil
    ]) {
        let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
        #expect(config.provider == .openai)
        #expect(config.effectiveBaseURL == "http://192.168.64.1:18081/relay/openai/v1")
        #expect(config.fallbackProvider == .openai)
        #expect(config.fallbackBaseURL == "http://192.168.64.1:18081/relay/openai/v1")
    }
}

@Test
func testConfigLoaderReadsFallbackSettingsFromConfigFile() async throws {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanoclaw-config-\(UUID().uuidString).json")
    let json = """
    {
      "api_key": "test-kimi-key",
      "model_provider": "kimi",
      "fallback_provider": "openai",
      "fallback_model": "gpt-4.1-mini",
      "fallback_base_url": "https://api.openai.com/v1",
      "fallback_api_key": "test-openai-key",
      "fallback_rpm_limit": "5"
    }
    """
    try Data(json.utf8).write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    try await TestEnvironmentLock.shared.withEnvs([
        "MOONSHOT_API_KEY": nil,
        "OPENAI_API_KEY": nil,
        "NANOCLAW_FALLBACK_PROVIDER": nil,
        "NANOCLAW_FALLBACK_MODEL": nil,
        "NANOCLAW_FALLBACK_BASE_URL": nil,
        "NANOCLAW_FALLBACK_API_KEY": nil,
        "NANOCLAW_FALLBACK_RPM_LIMIT": nil
    ]) {
        let config = try await ConfigLoader.load(from: tempURL.path)
        #expect(config.provider == .kimi)
        #expect(config.fallbackProvider == .openai)
        #expect(config.fallbackModel == .gpt41Mini)
        #expect(config.fallbackBaseURL == "https://api.openai.com/v1")
        #expect(config.fallbackAPIKey == "test-openai-key")
        #expect(config.fallbackRequestsPerMinuteLimit == 5)
    }
}
