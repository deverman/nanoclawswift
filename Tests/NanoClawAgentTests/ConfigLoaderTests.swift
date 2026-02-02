import Testing
@testable import NanoClawAgent

private func withEnv(_ key: String, _ value: String?, body: () async throws -> Void) async rethrows {
    if let value {
        setenv(key, value, 1)
    } else {
        unsetenv(key)
    }
    try await body()
    unsetenv(key)
}

@Test
func testConfigLoaderUsesOpenAIKey() async throws {
    try await withEnv("OPENAI_API_KEY", "test-openai-key") {
        try await withEnv("MODEL_PROVIDER", "openai") {
            let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
            #expect(config.provider == .openai)
            #expect(config.apiKey == "test-openai-key")
            #expect(config.model == .gpt52)
        }
    }
}

@Test
func testConfigLoaderRespectsModelOverride() async throws {
    try await withEnv("OPENAI_API_KEY", "test-openai-key") {
        try await withEnv("MODEL_PROVIDER", "openai") {
            try await withEnv("MODEL_NAME", "gpt-4o") {
                let config = try await ConfigLoader.load(from: "/tmp/nonexistent.json")
                #expect(config.provider == .openai)
                #expect(config.model == .gpt4o)
            }
        }
    }
}
