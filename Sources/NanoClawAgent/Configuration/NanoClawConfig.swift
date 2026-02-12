import Foundation

/// NanoClaw configuration structure
public struct NanoClawConfig: Codable, Sendable {
    public let apiKey: String
    public let provider: ModelProvider
    public let model: ModelName
    public let baseURL: String?
    public let timeout: Int
    public let maxTokens: Int?
    public let assistantName: String?
    
    public init(
        apiKey: String,
        provider: ModelProvider = .kimi,
        model: ModelName? = nil,
        baseURL: String? = nil,
        timeout: Int = 180,
        maxTokens: Int? = nil,
        assistantName: String? = nil
    ) {
        self.apiKey = apiKey
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.baseURL = baseURL
        self.timeout = timeout
        self.maxTokens = maxTokens
        self.assistantName = assistantName
    }
    
    /// Effective base URL (custom or provider default)
    public var effectiveBaseURL: String {
        baseURL ?? provider.defaultBaseURL
    }
}
