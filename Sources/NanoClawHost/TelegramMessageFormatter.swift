import Foundation

enum TelegramParseMode: String, Sendable {
    case html = "HTML"
}

struct TelegramFormattedMessage: Sendable {
    let text: String
    let parseMode: TelegramParseMode?
}

enum TelegramMessageFormatter {
    static func format(_ text: String) -> TelegramFormattedMessage {
        guard !text.isEmpty else {
            return TelegramFormattedMessage(text: text, parseMode: nil)
        }

        let boldRegex = try? NSRegularExpression(pattern: #"\*\*([^\n*][^*]*?)\*\*"#)
        let italicRegex = try? NSRegularExpression(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#)
        let codeRegex = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)

        var transformed = text
        var substitutions: [String: String] = [:]
        var hasFormatting = false
        var counter = 0

        func replace(regex: NSRegularExpression?, builder: (String) -> String?) {
            guard let regex else { return }
            let source = transformed
            let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
            let matches = regex.matches(in: source, options: [], range: nsRange)
            guard !matches.isEmpty else { return }

            var updated = source
            var applied = false
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let wholeRange = Range(match.range(at: 0), in: updated),
                      let captureRange = Range(match.range(at: 1), in: updated) else {
                    continue
                }
                let captured = String(updated[captureRange])
                guard let replacement = builder(captured) else {
                    continue
                }
                applied = true
                let token = "@@NCFMT_\(counter)@@"
                counter += 1
                substitutions[token] = replacement
                updated.replaceSubrange(wholeRange, with: token)
            }
            guard applied else { return }
            hasFormatting = true
            transformed = updated
        }

        replace(regex: codeRegex) { content in
            "<code>\(escapeHTML(content))</code>"
        }
        replace(regex: boldRegex) { content in
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "<b>\(escapeHTML(trimmed))</b>"
        }
        replace(regex: italicRegex) { content in
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
            return "<i>\(escapeHTML(trimmed))</i>"
        }

        guard hasFormatting else {
            return TelegramFormattedMessage(text: text, parseMode: nil)
        }

        var escaped = escapeHTML(transformed)
        for (token, replacement) in substitutions {
            let escapedToken = escapeHTML(token)
            escaped = escaped.replacingOccurrences(of: escapedToken, with: replacement)
        }

        return TelegramFormattedMessage(text: escaped, parseMode: .html)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
