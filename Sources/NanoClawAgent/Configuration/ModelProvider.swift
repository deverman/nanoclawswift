import Foundation

/// Supported LLM providers
public enum ModelProvider: String, Codable, CaseIterable, Sendable {
    case kimi = "kimi"
    case openai = "openai"
    case anthropic = "anthropic"
    
    /// Default base URL for each provider
    public var defaultBaseURL: String {
        switch self {
        case .kimi:
            return "https://api.moonshot.ai/v1"
        case .openai:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        }
    }
    
    /// Default model name for each provider
    public var defaultModel: ModelName {
        switch self {
        case .kimi:
            return .kimiK2_5
        case .openai:
            return .gpt52  // Latest GPT-5.2 model (released Dec 2025)
        case .anthropic:
            return .claude35Sonnet
        }
    }
}

/// Available model names across all providers
public enum ModelName: String, Codable, Sendable {
    // Kimi models
    case kimiK2 = "kimi-k2"
    case kimiK2_5 = "kimi-k2.5"
    
    // OpenAI models (GPT-5.2 series released Dec 2025)
    case gpt52 = "gpt-5.2"
    case gpt52Instant = "gpt-5.2-instant"
    case gpt52Thinking = "gpt-5.2-thinking"
    case gpt52Codex = "gpt-5.2-codex"
    // Legacy models
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case gpt4Turbo = "gpt-4-turbo"
    
    // Anthropic models
    case claude35Sonnet = "claude-3-5-sonnet-20241022"
    case claude3Opus = "claude-3-opus-20240229"
    case claude3Haiku = "claude-3-haiku-20240307"
}
