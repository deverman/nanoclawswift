import Foundation

enum ScheduledRunFailureCause: String, Sendable {
    case providerRateLimit = "provider_rate_limit"
    case providerTimeout = "provider_timeout"
    case networkOffline = "network_offline"
    case tokenOverflow = "token_overflow"
    case toolError = "tool_error"
    case unknown = "unknown"
}

enum ScheduledRunFailureClassifier {
    static func classify(status: String?, detail: String?) -> ScheduledRunFailureCause? {
        guard (status ?? "").lowercased() == "error" else { return nil }
        return classify(detail: detail)
    }

    static func classify(detail: String?) -> ScheduledRunFailureCause {
        let text = (detail ?? "").lowercased()
        if text.contains("http 429")
            || text.contains("rate limit exceeded")
            || text.contains("rate limit")
            || text.contains("rate limits")
            || text.contains("rate_limited")
            || text.contains("temporarily unavailable due to rate limits") {
            return .providerRateLimit
        }
        let upstreamTimeout =
            (text.contains("http 502") && text.contains("timed out"))
            || text.contains("http 504")
            || text.contains("timeout")
            || text.contains("timed out waiting for response")
            || text.contains("queue watchdog timed out")
            || text.contains("watchdog timed out")
        if upstreamTimeout {
            return .providerTimeout
        }
        if text.contains("internet connection appears to be offline")
            || text.contains("could not resolve host")
            || text.contains("name or service not known") {
            return .networkOffline
        }
        if text.contains("exceeded model token limit")
            || text.contains("maximum context length")
            || text.contains("context length") {
            return .tokenOverflow
        }
        if text.contains("tool"), text.contains("error") || text.contains("failed") {
            return .toolError
        }
        return .unknown
    }

    static func isTransient(_ cause: ScheduledRunFailureCause?) -> Bool {
        guard let cause else { return false }
        switch cause {
        case .providerRateLimit, .providerTimeout, .networkOffline:
            return true
        case .tokenOverflow, .toolError, .unknown:
            return false
        }
    }
}
