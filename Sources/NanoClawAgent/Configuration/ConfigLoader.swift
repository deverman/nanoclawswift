import Foundation

/// Loads configuration from JSON files and environment variables
public struct ConfigLoader {
    
    /// Load configuration from a JSON file path
    public static func load(from path: String) async throws -> NanoClawConfig {
        // First, check environment variables (highest priority)
        let envApiKey = ProcessInfo.processInfo.environment["API_KEY"]
        let envProvider = ProcessInfo.processInfo.environment["MODEL_PROVIDER"]
        let envModel = ProcessInfo.processInfo.environment["MODEL_NAME"]
        let envBaseURL = ProcessInfo.processInfo.environment["BASE_URL"]
        let envTimeout = ProcessInfo.processInfo.environment["TIMEOUT"]
        let envMaxTokens = ProcessInfo.processInfo.environment["MAX_TOKENS"]
        let envAssistantName = ProcessInfo.processInfo.environment["ASSISTANT_NAME"]
        
        // Load JSON config file
        let fileURL = URL(fileURLWithPath: path)
        let fileConfig: FileConfig
        
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: fileURL)
            fileConfig = try JSONDecoder().decode(FileConfig.self, from: data)
        } else {
            fileConfig = FileConfig() // Empty config
        }
        
        // Get required API key (env var takes priority)
        guard let apiKey = envApiKey ?? fileConfig.api_key else {
            throw ConfigError.missingRequiredKey("api_key")
        }
        
        // Parse provider enum (env var takes priority)
        let providerString = envProvider ?? fileConfig.model_provider ?? "kimi"
        guard let provider = ModelProvider(rawValue: providerString) else {
            throw ConfigError.invalidProvider(providerString)
        }
        
        // Parse model enum (optional, env var takes priority)
        let modelString = envModel ?? fileConfig.model_name
        let model: ModelName? = modelString.flatMap { ModelName(rawValue: $0) }
        
        // Other settings (env vars take priority)
        let timeout = Int(envTimeout ?? "") ?? fileConfig.timeout ?? 60
        let maxTokens = Int(envMaxTokens ?? "") ?? fileConfig.max_tokens
        let baseURL = envBaseURL ?? fileConfig.base_url
        let assistantName = envAssistantName ?? fileConfig.assistant_name
        
        return NanoClawConfig(
            apiKey: apiKey,
            provider: provider,
            model: model,
            baseURL: baseURL,
            timeout: timeout,
            maxTokens: maxTokens,
            assistantName: assistantName
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
