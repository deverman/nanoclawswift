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
    public let requestsPerMinuteLimit: Int?
    public let fallbackProvider: ModelProvider?
    public let fallbackAPIKey: String?
    public let fallbackModel: ModelName?
    public let fallbackBaseURL: String?
    public let fallbackRequestsPerMinuteLimit: Int?
    
    public init(
        apiKey: String,
        provider: ModelProvider = .kimi,
        model: ModelName? = nil,
        baseURL: String? = nil,
        timeout: Int = 180,
        maxTokens: Int? = nil,
        assistantName: String? = nil,
        requestsPerMinuteLimit: Int? = nil,
        fallbackProvider: ModelProvider? = nil,
        fallbackAPIKey: String? = nil,
        fallbackModel: ModelName? = nil,
        fallbackBaseURL: String? = nil,
        fallbackRequestsPerMinuteLimit: Int? = nil
    ) {
        self.apiKey = apiKey
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.baseURL = baseURL
        self.timeout = timeout
        self.maxTokens = maxTokens
        self.assistantName = assistantName
        self.requestsPerMinuteLimit = requestsPerMinuteLimit
        self.fallbackProvider = fallbackProvider
        self.fallbackAPIKey = fallbackAPIKey
        self.fallbackModel = fallbackModel
        self.fallbackBaseURL = fallbackBaseURL
        self.fallbackRequestsPerMinuteLimit = fallbackRequestsPerMinuteLimit
    }
    
    /// Effective base URL (custom or provider default)
    public var effectiveBaseURL: String {
        baseURL ?? provider.defaultBaseURL
    }
}
