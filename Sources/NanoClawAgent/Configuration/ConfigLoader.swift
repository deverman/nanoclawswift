import Foundation

/// Loads configuration from JSON files and environment variables
public struct ConfigLoader {
    private static let defaultTimeoutSeconds = 180
    
    /// Load configuration from a JSON file path
    public static func load(from path: String) async throws -> NanoClawConfig {
        // First, check environment variables (highest priority)
        // Support multiple API providers: check for their specific keys
        let envMoonshotKey = ProcessInfo.processInfo.environment["MOONSHOT_API_KEY"]
        let envOpenAIKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        let envAnthropicKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        
        let envProvider = ProcessInfo.processInfo.environment["MODEL_PROVIDER"]
        let envModel = ProcessInfo.processInfo.environment["MODEL_NAME"]
        let envBaseURL = ProcessInfo.processInfo.environment["BASE_URL"]
        let envTimeout = ProcessInfo.processInfo.environment["TIMEOUT"]
        let envMaxTokens = ProcessInfo.processInfo.environment["MAX_TOKENS"]
        let envAssistantName = ProcessInfo.processInfo.environment["ASSISTANT_NAME"]
        let envProviderRPM = ProcessInfo.processInfo.environment["NANOCLAW_PROVIDER_RPM_LIMIT"]
        let envKimiRPM = ProcessInfo.processInfo.environment["KIMI_RPM_LIMIT"]
        let envFallbackProvider = ProcessInfo.processInfo.environment["NANOCLAW_FALLBACK_PROVIDER"]
        let envFallbackModel = ProcessInfo.processInfo.environment["NANOCLAW_FALLBACK_MODEL"]
        let envFallbackBaseURL = ProcessInfo.processInfo.environment["NANOCLAW_FALLBACK_BASE_URL"]
        let envFallbackAPIKey = ProcessInfo.processInfo.environment["NANOCLAW_FALLBACK_API_KEY"]
        let envFallbackRPM = ProcessInfo.processInfo.environment["NANOCLAW_FALLBACK_RPM_LIMIT"]
        
        // Load JSON config file
        let fileURL = URL(fileURLWithPath: path)
        let fileConfig: FileConfig
        
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: fileURL)
            fileConfig = try JSONDecoder().decode(FileConfig.self, from: data)
        } else {
            fileConfig = FileConfig() // Empty config
        }
        
        // Determine which provider to use based on available API keys
        // Priority: Explicit provider setting > Available key detection
        let providerString: String
        let apiKey: String
        let defaultBaseURL: String
        let defaultModel: ModelName
        
        if let explicitProvider = envProvider ?? fileConfig.model_provider {
            // User explicitly specified a provider
            providerString = explicitProvider
            
            // Get the appropriate key for the explicit provider
            switch ModelProvider(rawValue: explicitProvider) {
            case .kimi:
                guard let key = envMoonshotKey ?? fileConfig.api_key else {
                    throw ConfigError.missingRequiredKey("MOONSHOT_API_KEY for kimi provider")
                }
                apiKey = key
                defaultBaseURL = ModelProvider.kimi.defaultBaseURL
                defaultModel = ModelProvider.kimi.defaultModel
                
            case .openai:
                guard let key = envOpenAIKey ?? envMoonshotKey ?? fileConfig.api_key else {
                    throw ConfigError.missingRequiredKey("OPENAI_API_KEY for openai provider")
                }
                apiKey = key
                defaultBaseURL = ModelProvider.openai.defaultBaseURL
                defaultModel = ModelProvider.openai.defaultModel
                
            case .anthropic:
                guard let key = envAnthropicKey ?? envMoonshotKey ?? fileConfig.api_key else {
                    throw ConfigError.missingRequiredKey("ANTHROPIC_API_KEY for anthropic provider")
                }
                apiKey = key
                defaultBaseURL = ModelProvider.anthropic.defaultBaseURL
                defaultModel = ModelProvider.anthropic.defaultModel
                
            default:
                throw ConfigError.invalidProvider(explicitProvider)
            }
        } else {
            // Auto-detect provider based on available keys
            if let key = envOpenAIKey {
                // OpenAI key available
                apiKey = key
                providerString = "openai"
                defaultBaseURL = ModelProvider.openai.defaultBaseURL
                defaultModel = ModelProvider.openai.defaultModel
            } else if let key = envMoonshotKey {
                // Moonshot/Kimi key available
                apiKey = key
                providerString = "kimi"
                defaultBaseURL = ModelProvider.kimi.defaultBaseURL
                defaultModel = ModelProvider.kimi.defaultModel
            } else if let key = envAnthropicKey {
                // Anthropic key available
                apiKey = key
                providerString = "anthropic"
                defaultBaseURL = ModelProvider.anthropic.defaultBaseURL
                defaultModel = ModelProvider.anthropic.defaultModel
            } else if let key = fileConfig.api_key {
                // Fall back to config file key with default kimi provider
                apiKey = key
                providerString = "kimi"
                defaultBaseURL = ModelProvider.kimi.defaultBaseURL
                defaultModel = ModelProvider.kimi.defaultModel
            } else {
                throw ConfigError.missingRequiredKey("api_key (set MOONSHOT_API_KEY, OPENAI_API_KEY, or ANTHROPIC_API_KEY)")
            }
        }
        
        guard let provider = ModelProvider(rawValue: providerString) else {
            throw ConfigError.invalidProvider(providerString)
        }
        
        // Parse model enum (optional, env var takes priority, then default for provider)
        let model: ModelName
        if let modelString = envModel ?? fileConfig.model_name,
           let parsedModel = ModelName(rawValue: modelString) {
            model = parsedModel
        } else {
            model = defaultModel
        }
        
        // Other settings (env vars take priority)
        let timeout = Int(envTimeout ?? "") ?? fileConfig.timeout ?? defaultTimeoutSeconds
        let maxTokens = Int(envMaxTokens ?? "") ?? fileConfig.max_tokens
        let baseURL = envBaseURL ?? fileConfig.base_url ?? defaultBaseURL
        let assistantName = envAssistantName ?? fileConfig.assistant_name
        let requestsPerMinuteLimit: Int? = {
            if let explicit = Int(envProviderRPM ?? ""), explicit > 0 {
                return explicit
            }
            if provider == .kimi {
                if let kimiValue = Int(envKimiRPM ?? ""), kimiValue > 0 {
                    return kimiValue
                }
                return 8
            }
            return nil
        }()
        let fallbackProvider: ModelProvider? = {
            guard let raw = envFallbackProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return ModelProvider(rawValue: raw)
        }()
        let fallbackModel: ModelName? = {
            guard let raw = envFallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return ModelName(rawValue: raw)
        }()
        let fallbackAPIKey: String? = {
            guard let fallbackProvider else { return nil }
            if let explicit = envFallbackAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty {
                return explicit
            }
            switch fallbackProvider {
            case .openai:
                return envOpenAIKey
            case .kimi:
                return envMoonshotKey
            case .anthropic:
                return envAnthropicKey
            }
        }()
        let fallbackRequestsPerMinuteLimit: Int? = {
            if let raw = envFallbackRPM, let parsed = Int(raw), parsed > 0 {
                return parsed
            }
            return nil
        }()
        
        return NanoClawConfig(
            apiKey: apiKey,
            provider: provider,
            model: model,
            baseURL: baseURL,
            timeout: timeout,
            maxTokens: maxTokens,
            assistantName: assistantName,
            requestsPerMinuteLimit: requestsPerMinuteLimit,
            fallbackProvider: fallbackProvider,
            fallbackAPIKey: fallbackAPIKey,
            fallbackModel: fallbackModel,
            fallbackBaseURL: envFallbackBaseURL,
            fallbackRequestsPerMinuteLimit: fallbackRequestsPerMinuteLimit
        )
    }
}

/// File-based configuration structure (matches JSON format)
private struct FileConfig: Codable {
    var api_key: String?
    var model_provider: String?
    var model_name: String?
    var base_url: String?
    var timeout: Int?
    var max_tokens: Int?
    var assistant_name: String?
}

/// Configuration loading errors
public enum ConfigError: Error {
    case missingRequiredKey(String)
    case invalidProvider(String)
    case fileNotFound(String)
    case invalidJSON(String)
    
    public var description: String {
        switch self {
        case .missingRequiredKey(let key):
            return "Missing required configuration key: \(key)"
        case .invalidProvider(let provider):
            return "Invalid model provider: \(provider). Valid options: \(ModelProvider.allCases.map { $0.rawValue }.joined(separator: ", "))"
        case .fileNotFound(let path):
            return "Configuration file not found: \(path)"
        case .invalidJSON(let path):
            return "Invalid JSON in configuration file: \(path)"
        }
    }
}
