import Foundation

enum SchedulerFailureCause: String, Sendable {
    case providerRateLimit = "provider_rate_limit"
    case providerTimeout = "provider_timeout"
    case networkOffline = "network_offline"
    case tokenOverflow = "token_overflow"
    case missingToolCalls = "missing_tool_calls"
    case staleContent = "stale_content"
    case toolError = "tool_error"
    case unknown = "unknown"
}

enum SchedulerDiagnosticsClassifier {
    static func classify(status: String?, detail: String?) -> SchedulerFailureCause? {
        guard (status ?? "").lowercased() == "error" else { return nil }
        return classify(detail: detail)
    }

    static func classify(detail: String?) -> SchedulerFailureCause {
        let text = (detail ?? "").lowercased()
        if text.contains("http 429") || text.contains("rate limit exceeded") {
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
        if text.contains("required tool execution")
            && text.contains("no structured tool calls") {
            return .missingToolCalls
        }
        if text.contains("did not issue a valid structured tool call") {
            return .missingToolCalls
        }
        if text.contains("pseudo tool syntax")
            || text.contains("structured tool calls")
            || text.contains("function_calls")
            || text.contains("<invoke") {
            return .missingToolCalls
        }
        if text.contains("freshness check failed")
            || text.contains("missing dated sources")
            || text.contains("all cited source dates are older than") {
            return .staleContent
        }
        if text.contains("tool"), text.contains("error") || text.contains("failed") {
            return .toolError
        }
        return .unknown
    }
}

struct SchedulerFallbackObservation: Equatable {
    let taskID: String
    let used: Bool
    let reason: String
}

enum SchedulerDiagnosticsLogParser {
    static func fallbackObservation(from line: String) -> SchedulerFallbackObservation? {
        guard line.contains("Completed scheduled queue job"),
              line.contains("providerFallbackUsed=") else {
            return nil
        }

        guard let requestRange = line.range(of: "request=sched-") else {
            return nil
        }
        let requestTail = line[requestRange.upperBound...]
        let requestID = requestTail.split(separator: " ").first.map(String.init) ?? ""
        guard !requestID.isEmpty else { return nil }

        let taskID = extractTaskID(fromScheduledRequestID: requestID)
        guard !taskID.isEmpty else { return nil }

        let used = line.contains("providerFallbackUsed=true")
        let reason = extractField(named: "providerFallbackReason", from: line) ?? "none"
        return SchedulerFallbackObservation(taskID: taskID, used: used, reason: reason)
    }

    private static func extractTaskID(fromScheduledRequestID requestID: String) -> String {
        guard requestID.hasPrefix("task-") else { return "" }
        guard let lastDash = requestID.lastIndex(of: "-") else { return requestID }
        let suffix = requestID[requestID.index(after: lastDash)...]
        if suffix.allSatisfy(\.isNumber) {
            return String(requestID[..<lastDash])
        }
        return requestID
    }

    private static func extractField(named name: String, from line: String) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        let tail = line[range.upperBound...]
        let value = tail.split(separator: " ").first.map(String.init) ?? ""
        return value.isEmpty ? nil : value
    }
}
