import ArgumentParser
import Foundation

struct TurnSummary {
    let timestamp: String
    let input: String
    let toolNames: [String]
    let hadError: Bool
    let hadToolError: Bool
    let webSearchResultCounts: [Int]
    let notes: [String]
}

@main
struct SessionSummaryCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-summary",
        abstract: "Summarize NanoClaw archived session turns for one group."
    )

    @Argument(help: "Group folder name under groups/.")
    var groupFolder: String = "telegram-direct"

    @Option(help: "Only include turns on/after this ISO8601 UTC timestamp (for example: 2026-02-11T10:45:00Z).")
    var since: String?

    @Option(help: "Analyze only the most recent N turns.")
    var limit: Int?

    mutating func run() throws {
        let sinceDate = parseSinceDate(since)
        let archiveDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("groups")
            .appendingPathComponent(groupFolder)
            .appendingPathComponent(".nanoclaw")
            .appendingPathComponent("archive")

        guard FileManager.default.fileExists(atPath: archiveDir.path) else {
            throw ValidationError("Archive directory not found: \(archiveDir.path)")
        }

        var turns = try loadTurns(from: archiveDir, since: sinceDate)
        if let limit, limit > 0, turns.count > limit {
            turns = Array(turns.suffix(limit))
        }

        let withErrors = turns.filter { $0.hadError || $0.hadToolError }
        let withPolicyDenied = turns.filter { $0.notes.contains("policy denied domain") }
        let withWebSearch = turns.filter { $0.toolNames.contains("web_search") }
        let emptySearches = withWebSearch.filter {
            !$0.webSearchResultCounts.isEmpty && $0.webSearchResultCounts.allSatisfy { $0 == 0 }
        }

        print("Session summary for group: \(groupFolder)")
        if let sinceDate {
            print("Since: \(isoFormatter.string(from: sinceDate))")
        }
        print("Turns analyzed: \(turns.count)")
        print("Turns with tool/runtime errors: \(withErrors.count)")
        print("Turns with policy-denied fetches: \(withPolicyDenied.count)")
        print("Turns using web_search: \(withWebSearch.count)")
        print("web_search turns with only empty results: \(emptySearches.count)")
        if !withWebSearch.isEmpty && emptySearches.count == withWebSearch.count {
            print("Search diagnosis: likely provider/result-shape limitation (not API-key auth).")
        }

        print("\nRecent turns:")
        for turn in turns.suffix(10) {
            let tools = turn.toolNames.isEmpty ? "-" : turn.toolNames.joined(separator: ",")
            let notes = turn.notes.isEmpty ? "-" : turn.notes.joined(separator: "; ")
            print("- \(turn.timestamp) | input=\"\(shortText(turn.input))\" | tools=\(tools) | notes=\(notes)")
        }
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoFormatterNoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private func parseSinceDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    if let withFractional = isoFormatter.date(from: raw) {
        return withFractional
    }
    return isoFormatterNoFractional.date(from: raw)
}

private func shortText(_ value: String, max: Int = 80) -> String {
    let compact = value.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    if compact.count <= max { return compact }
    return String(compact.prefix(max - 1)) + "..."
}

private func parseMaybeDoubleEncodedJSON(_ raw: String) -> Any? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
    if let parsed = try? JSONSerialization.jsonObject(with: data) {
        if let nested = parsed as? String,
           let nestedData = nested.data(using: .utf8),
           let nestedParsed = try? JSONSerialization.jsonObject(with: nestedData) {
            return nestedParsed
        }
        return parsed
    }

    // Fallback for legacy payloads that include an extra wrapping quote layer.
    if trimmed.first == "\"", trimmed.last == "\"", trimmed.count >= 2 {
        let unwrapped = String(trimmed.dropFirst().dropLast())
        if let unwrappedData = unwrapped.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: unwrappedData) {
            return parsed
        }
    }

    return nil
}

private func loadTurns(from archiveDir: URL, since: Date?) throws -> [TurnSummary] {
    let files = try FileManager.default.contentsOfDirectory(
        at: archiveDir,
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var turns: [TurnSummary] = []

    for file in files {
        let data = try Data(contentsOf: file)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }
        guard let entries = root["entries"] as? [[String: Any]], !entries.isEmpty else {
            continue
        }

        let agentStart = entries.first(where: { ($0["event"] as? String) == "agentStart" })
        let agentEnd = entries.reversed().first(where: { ($0["event"] as? String) == "agentEnd" })
        let timestamp = (agentStart?["timestamp"] as? String)
            ?? (root["timestamp"] as? String)
            ?? String(file.lastPathComponent.prefix(20))

        if let since,
           let turnDate = isoFormatter.date(from: timestamp) ?? isoFormatterNoFractional.date(from: timestamp),
           turnDate < since {
            continue
        }

        let toolStarts = entries.filter { ($0["event"] as? String) == "toolStart" }
        let toolEnds = entries.filter { ($0["event"] as? String) == "toolEnd" }
        let errors = entries.filter { ($0["event"] as? String) == "error" }

        var notes = Set<String>()
        var webSearchResultCounts: [Int] = []

        for entry in toolEnds {
            let toolName = entry["toolName"] as? String ?? ""
            let result = entry["result"] as? String ?? ""

            if toolName == "web_search",
               let parsed = parseMaybeDoubleEncodedJSON(result) as? [String: Any],
               let results = parsed["results"] as? [Any] {
                webSearchResultCounts.append(results.count)
                if results.isEmpty {
                    notes.insert("web_search returned 0 results")
                }
            }

            if result.range(of: "Policy denied domain", options: .caseInsensitive) != nil {
                notes.insert("policy denied domain")
            }

            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\"Error:") || trimmed.hasPrefix("Error:") {
                notes.insert("tool returned error")
            }
        }

        if agentEnd == nil {
            notes.insert("missing agentEnd")
        }

        turns.append(
            TurnSummary(
                timestamp: timestamp,
                input: (agentStart?["input"] as? String) ?? "(unknown)",
                toolNames: toolStarts.compactMap { $0["toolName"] as? String },
                hadError: !errors.isEmpty,
                hadToolError: notes.contains("tool returned error"),
                webSearchResultCounts: webSearchResultCounts,
                notes: Array(notes).sorted()
            )
        )
    }

    return turns
}
