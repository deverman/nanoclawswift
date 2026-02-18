import Foundation

struct TelegramMessageSplitter {
    static let defaultLimit = 4096

    static func split(_ text: String, limit: Int = defaultLimit) -> [String] {
        guard limit > 0 else { return [text] }
        guard text.count > limit else { return [text] }

        let tokens = tokenize(text)
        var chunks: [String] = []
        var current = ""
        current.reserveCapacity(min(limit, text.count))

        for token in tokens {
            if token.isCodeFence {
                appendCodeToken(token.text, limit: limit, current: &current, chunks: &chunks)
            } else {
                appendPlainToken(token.text, limit: limit, current: &current, chunks: &chunks)
            }
        }

        flushCurrent(&current, chunks: &chunks)
        return chunks
    }

    private struct Token {
        let text: String
        let isCodeFence: Bool
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard let openingRange = text[index...].range(of: "```") else {
                tokens.append(Token(text: String(text[index...]), isCodeFence: false))
                break
            }

            if openingRange.lowerBound > index {
                tokens.append(Token(text: String(text[index..<openingRange.lowerBound]), isCodeFence: false))
            }

            let bodyStart = openingRange.upperBound
            guard let closingRange = text[bodyStart...].range(of: "```") else {
                tokens.append(Token(text: String(text[openingRange.lowerBound...]), isCodeFence: false))
                break
            }

            tokens.append(Token(text: String(text[openingRange.lowerBound..<closingRange.upperBound]), isCodeFence: true))
            index = closingRange.upperBound
        }

        return tokens
    }

    private static func appendPlainToken(
        _ token: String,
        limit: Int,
        current: inout String,
        chunks: inout [String]
    ) {
        var remaining = token
        while !remaining.isEmpty {
            if current.count == limit {
                flushCurrent(&current, chunks: &chunks)
            }

            let available = limit - current.count
            if available <= 0 {
                flushCurrent(&current, chunks: &chunks)
                continue
            }

            if remaining.count <= available {
                current += remaining
                break
            }

            let maxIndex = remaining.index(remaining.startIndex, offsetBy: available)
            let splitIndex = preferredSplitIndex(in: remaining, upTo: maxIndex) ?? maxIndex

            if splitIndex == remaining.startIndex {
                let nextIndex = remaining.index(after: remaining.startIndex)
                current += remaining[remaining.startIndex..<nextIndex]
                remaining = String(remaining[nextIndex...])
                if current.count >= limit {
                    flushCurrent(&current, chunks: &chunks)
                }
                continue
            }

            current += remaining[remaining.startIndex..<splitIndex]
            flushCurrent(&current, chunks: &chunks)
            remaining = String(remaining[splitIndex...])
        }
    }

    private static func appendCodeToken(
        _ token: String,
        limit: Int,
        current: inout String,
        chunks: inout [String]
    ) {
        if token.count <= limit {
            if !current.isEmpty, current.count + token.count > limit {
                flushCurrent(&current, chunks: &chunks)
            }
            current += token
            return
        }

        flushCurrent(&current, chunks: &chunks)

        for part in splitOversizedCodeFence(token, limit: limit) {
            if part.count <= limit {
                chunks.append(part)
            } else {
                appendPlainToken(part, limit: limit, current: &current, chunks: &chunks)
            }
        }
    }

    private static func preferredSplitIndex(in text: String, upTo upperBound: String.Index) -> String.Index? {
        let prefix = text[..<upperBound]

        if let newlineIndex = prefix.lastIndex(of: "\n") {
            return text.index(after: newlineIndex)
        }

        if let whitespaceIndex = prefix.lastIndex(where: { $0 == " " || $0 == "\t" }) {
            return text.index(after: whitespaceIndex)
        }

        return nil
    }

    private static func splitOversizedCodeFence(_ token: String, limit: Int) -> [String] {
        guard token.hasPrefix("```"),
              let closingRange = token.range(of: "```", options: .backwards),
              closingRange.lowerBound > token.startIndex else {
            return hardSplit(token, limit: limit)
        }

        let openingTicksEnd = token.index(token.startIndex, offsetBy: 3)
        let headerEnd = token[openingTicksEnd...].firstIndex(of: "\n") ?? openingTicksEnd
        let language = String(token[openingTicksEnd..<headerEnd])

        let bodyStart: String.Index = if headerEnd < token.endIndex {
            token.index(after: headerEnd)
        } else {
            headerEnd
        }
        let bodyEnd = closingRange.lowerBound
        guard bodyStart <= bodyEnd else {
            return hardSplit(token, limit: limit)
        }

        let body = String(token[bodyStart..<bodyEnd])
        let opening = "```\(language)\n"
        let closing = "\n```"
        let maxBodyCharacters = limit - opening.count - closing.count
        guard maxBodyCharacters > 0 else {
            return hardSplit(token, limit: limit)
        }

        var chunks: [String] = []
        var remaining = body

        while !remaining.isEmpty {
            if remaining.count <= maxBodyCharacters {
                chunks.append(opening + remaining + closing)
                break
            }

            let upperBound = remaining.index(remaining.startIndex, offsetBy: maxBodyCharacters)
            let splitIndex = preferredSplitIndex(in: remaining, upTo: upperBound) ?? upperBound

            if splitIndex == remaining.startIndex {
                let nextIndex = remaining.index(after: remaining.startIndex)
                let slice = String(remaining[remaining.startIndex..<nextIndex])
                chunks.append(opening + slice + closing)
                remaining = String(remaining[nextIndex...])
                continue
            }

            let slice = String(remaining[remaining.startIndex..<splitIndex])
            chunks.append(opening + slice + closing)
            remaining = String(remaining[splitIndex...])
        }

        return chunks
    }

    private static func hardSplit(_ text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [text] }

        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            let length = min(limit, remaining.count)
            let endIndex = remaining.index(remaining.startIndex, offsetBy: length)
            chunks.append(String(remaining[..<endIndex]))
            remaining = String(remaining[endIndex...])
        }

        return chunks
    }

    private static func flushCurrent(_ current: inout String, chunks: inout [String]) {
        guard !current.isEmpty else { return }
        chunks.append(current)
        current.removeAll(keepingCapacity: true)
    }
}

func splitOutboundText(_ text: String, for channel: String, limit: Int = TelegramMessageSplitter.defaultLimit) -> [String] {
    if channel == "telegram" {
        return TelegramMessageSplitter.split(text, limit: limit)
    }
    return [text]
}

func splitAssistantOutboundText(
    _ modelText: String,
    assistantName: String,
    for channel: String,
    limit: Int = TelegramMessageSplitter.defaultLimit
) -> [String] {
    splitOutboundText("\(assistantName): \(modelText)", for: channel, limit: limit)
}
