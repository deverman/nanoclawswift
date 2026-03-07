import Foundation

enum LLMRelayMode: String, Sendable {
    case off
    case auto
    case force

    static func parse(_ raw: String) -> LLMRelayMode {
        LLMRelayMode(rawValue: raw.lowercased()) ?? .auto
    }
}

enum LLMRelayProvider: String, Sendable {
    case openai
    case kimi
    case anthropic

    var upstreamBaseURL: URL {
        switch self {
        case .openai:
            return URL(string: "https://api.openai.com")!
        case .kimi:
            return URL(string: "https://api.moonshot.ai")!
        case .anthropic:
            return URL(string: "https://api.anthropic.com")!
        }
    }
}

struct LLMRelaySettings: Sendable {
    let mode: LLMRelayMode
    let bindHost: String
    let advertiseHost: String
    let port: Int

    var relayBaseRoot: String {
        "http://\(advertiseHost):\(port)"
    }
}

enum LLMRelayConfig {
    struct ResolvedRoute: Sendable, Equatable {
        let provider: LLMRelayProvider
        let upstreamURL: URL
    }

    static func resolveProvider(from passthrough: [String: String]) -> LLMRelayProvider {
        if let explicit = passthrough["MODEL_PROVIDER"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch explicit {
            case "openai":
                return .openai
            case "anthropic":
                return .anthropic
            case "kimi", "moonshot":
                return .kimi
            default:
                break
            }
        }

        if let key = passthrough["OPENAI_API_KEY"], !key.isEmpty {
            return .openai
        }
        if let key = passthrough["MOONSHOT_API_KEY"], !key.isEmpty {
            return .kimi
        }
        if let key = passthrough["ANTHROPIC_API_KEY"], !key.isEmpty {
            return .anthropic
        }
        return .kimi
    }

    static func applyRelayBaseURLIfNeeded(
        passthrough: [String: String],
        settings: LLMRelaySettings
    ) -> [String: String] {
        guard settings.mode != .off else {
            return passthrough
        }

        var updated = passthrough
        let existingBaseURL = passthrough["BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldInject = settings.mode == .force || existingBaseURL.isEmpty
        if shouldInject {
            let provider = resolveProvider(from: passthrough)
            updated["BASE_URL"] = relayBaseURL(for: provider, settings: settings)
        }

        applyFallbackRelayBaseURLIfNeeded(updated: &updated, settings: settings)
        return updated
    }

    static func resolveRelayRoute(path: String) -> ResolvedRoute? {
        // Expected shape: /relay/{provider}/v1/{...}
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 4 else { return nil }
        guard components[0] == "relay",
              let provider = LLMRelayProvider(rawValue: String(components[1])),
              components[2] == "v1" else {
            return nil
        }

        let suffix = components.dropFirst(2).joined(separator: "/")
        guard !suffix.isEmpty else { return nil }
        let upstream = provider.upstreamBaseURL.appendingPathComponent(suffix)
        return ResolvedRoute(provider: provider, upstreamURL: upstream)
    }

    private static func relayBaseURL(for provider: LLMRelayProvider, settings: LLMRelaySettings) -> String {
        "\(settings.relayBaseRoot)/relay/\(provider.rawValue)/v1"
    }

    private static func resolveFallbackProvider(from passthrough: [String: String]) -> LLMRelayProvider? {
        guard let raw = passthrough["NANOCLAW_FALLBACK_PROVIDER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "openai":
            return .openai
        case "anthropic":
            return .anthropic
        case "kimi", "moonshot":
            return .kimi
        default:
            return nil
        }
    }

    private static func applyFallbackRelayBaseURLIfNeeded(
        updated: inout [String: String],
        settings: LLMRelaySettings
    ) {
        guard let fallbackProvider = resolveFallbackProvider(from: updated) else { return }
        let fallbackRelay = relayBaseURL(for: fallbackProvider, settings: settings)
        let current = updated["NANOCLAW_FALLBACK_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if settings.mode == .force {
            updated["NANOCLAW_FALLBACK_BASE_URL"] = fallbackRelay
            return
        }

        if current.isEmpty || current.lowercased().hasPrefix(fallbackProvider.upstreamBaseURL.absoluteString.lowercased()) {
            updated["NANOCLAW_FALLBACK_BASE_URL"] = fallbackRelay
        }
    }
}
