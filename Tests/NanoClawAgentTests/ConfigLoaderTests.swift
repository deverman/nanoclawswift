import Testing
@testable import NanoClawAgent

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
