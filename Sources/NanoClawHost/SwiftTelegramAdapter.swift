import Foundation
import Logging

protocol TelegramTransport: Sendable {
    func sendMessage(chatJID: String, text: String) async throws
    func sendDocument(chatJID: String, filePath: String, caption: String?) async throws
    func sendTyping(chatJID: String) async throws
}

enum TelegramChatIDResolver {
    static func resolve(_ chatJID: String) -> Int? {
        guard chatJID.hasPrefix("telegram_"),
              let atSymbol = chatJID.firstIndex(of: "@") else {
            return nil
        }

        let idStart = chatJID.index(chatJID.startIndex, offsetBy: "telegram_".count)
        guard idStart < atSymbol else { return nil }

        let rawID = String(chatJID[idStart..<atSymbol])
        return Int(rawID)
    }
}

enum TelegramTransportError: Error, CustomStringConvertible {
    case invalidChatJID(String)
    case invalidBaseURL(String)
    case invalidHTTPResponse
    case httpStatus(code: Int, bodyPreview: String)
    case apiRejected(code: Int?, description: String?)
    case missingBotToken
    case invalidAttachmentPath(String)

    var description: String {
        switch self {
        case let .invalidChatJID(chatJID):
            return "Invalid Telegram chat JID: \(chatJID)"
        case let .invalidBaseURL(raw):
            return "Invalid Telegram API base URL: \(raw)"
        case .invalidHTTPResponse:
            return "Telegram API returned a non-HTTP response"
        case let .httpStatus(code, bodyPreview):
            return "Telegram API HTTP \(code): \(bodyPreview)"
        case let .apiRejected(code, description):
            return "Telegram API rejected request code=\(code.map(String.init) ?? "none") description=\(description ?? "none")"
        case .missingBotToken:
            return "Telegram bot token is required for Swift transport"
        case let .invalidAttachmentPath(path):
            return "Attachment file not found at path: \(path)"
        }
    }
}

struct TelegramDeliveryRetrier: Sendable {
    let maxAttempts: Int
    let initialBackoffMs: Int
    let maxBackoffMs: Int

    init(maxAttempts: Int, initialBackoffMs: Int, maxBackoffMs: Int) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoffMs = max(1, initialBackoffMs)
        self.maxBackoffMs = max(self.initialBackoffMs, maxBackoffMs)
    }

    func sendMessage(
        chatJID: String,
        text: String,
        transport: any TelegramTransport
    ) async -> Result<Void, Error> {
        await performWithRetry {
            try await transport.sendMessage(chatJID: chatJID, text: text)
        }
    }

    func sendTyping(chatJID: String, transport: any TelegramTransport) async -> Result<Void, Error> {
        await performWithRetry {
            try await transport.sendTyping(chatJID: chatJID)
        }
    }

    func sendDocument(
        chatJID: String,
        filePath: String,
        caption: String?,
        transport: any TelegramTransport
    ) async -> Result<Void, Error> {
        await performWithRetry {
            try await transport.sendDocument(chatJID: chatJID, filePath: filePath, caption: caption)
        }
    }

    private func performWithRetry(operation: @escaping @Sendable () async throws -> Void) async -> Result<Void, Error> {
        var attempt = 1
        while attempt <= maxAttempts {
            do {
                try await operation()
                return .success(())
            } catch {
                guard attempt < maxAttempts, shouldRetry(error) else {
                    return .failure(error)
                }

                let delayMs = retryDelayMs(forAttempt: attempt)
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            attempt += 1
        }
        return .failure(URLError(.unknown))
    }

    private func retryDelayMs(forAttempt attempt: Int) -> Int {
        let shift = min(max(0, attempt - 1), 10)
        let multiplier = 1 << shift
        let candidate = initialBackoffMs * multiplier
        return min(maxBackoffMs, candidate)
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                    .cannotFindHost,
                    .cannotConnectToHost,
                    .dnsLookupFailed,
                    .networkConnectionLost,
                    .notConnectedToInternet,
                    .resourceUnavailable:
                return true
            default:
                return false
            }
        }

        if let transportError = error as? TelegramTransportError {
            switch transportError {
            case let .httpStatus(code, _):
                return code == 408 || code == 429 || code >= 500
            case let .apiRejected(code, _):
                guard let code else { return false }
                return code == 429 || code >= 500
            default:
                return false
            }
        }

        return false
    }
}

actor TelegramBotAPITransport: TelegramTransport {
    private struct SendMessageRequest: Encodable {
        let chat_id: Int
        let text: String
        let parse_mode: String?
    }

    private struct SendChatActionRequest: Encodable {
        let chat_id: Int
        let action: String
    }

    private struct APIEnvelope: Decodable {
        let ok: Bool
        let error_code: Int?
        let description: String?
    }

    private let botToken: String
    private let apiBaseURL: URL
    private let session: URLSession
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        botToken: String,
        logger: Logger,
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://api.telegram.org")!
    ) {
        self.botToken = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.logger = logger
        self.session = session
        self.apiBaseURL = apiBaseURL
    }

    func sendMessage(chatJID: String, text: String) async throws {
        let chatID = try parseChatID(chatJID)
        let formatted = TelegramMessageFormatter.format(text)
        try await post(
            endpoint: "sendMessage",
            body: SendMessageRequest(
                chat_id: chatID,
                text: formatted.text,
                parse_mode: formatted.parseMode?.rawValue
            )
        )
    }

    func sendTyping(chatJID: String) async throws {
        let chatID = try parseChatID(chatJID)
        try await post(
            endpoint: "sendChatAction",
            body: SendChatActionRequest(chat_id: chatID, action: "typing")
        )
    }

    func sendDocument(chatJID: String, filePath: String, caption: String?) async throws {
        let chatID = try parseChatID(chatJID)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw TelegramTransportError.invalidAttachmentPath(filePath)
        }

        let formattedCaption = caption.map(TelegramMessageFormatter.format)
        try await postMultipartDocument(
            endpoint: "sendDocument",
            chatID: chatID,
            filePath: filePath,
            caption: formattedCaption?.text,
            parseMode: formattedCaption?.parseMode?.rawValue
        )
    }

    private func parseChatID(_ chatJID: String) throws -> Int {
        guard let chatID = TelegramChatIDResolver.resolve(chatJID) else {
            throw TelegramTransportError.invalidChatJID(chatJID)
        }
        return chatID
    }

    static func requestURL(apiBaseURL: URL, botToken: String, endpoint: String) -> URL? {
        guard !botToken.isEmpty, !endpoint.isEmpty else {
            return nil
        }

        var url = apiBaseURL
        if !url.absoluteString.hasSuffix("/") {
            url.appendPathComponent("")
        }
        url.appendPathComponent("bot\(botToken)")
        url.appendPathComponent(endpoint)
        return url
    }

    private func post<RequestBody: Encodable>(endpoint: String, body: RequestBody) async throws {
        guard !botToken.isEmpty else {
            throw TelegramTransportError.missingBotToken
        }

        guard let requestURL = Self.requestURL(
            apiBaseURL: apiBaseURL,
            botToken: botToken,
            endpoint: endpoint
        ) else {
            throw TelegramTransportError.invalidBaseURL(apiBaseURL.absoluteString)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelegramTransportError.invalidHTTPResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            throw TelegramTransportError.httpStatus(
                code: httpResponse.statusCode,
                bodyPreview: bodyPreview(from: data)
            )
        }

        if let envelope = try? decoder.decode(APIEnvelope.self, from: data),
           envelope.ok == false {
            throw TelegramTransportError.apiRejected(
                code: envelope.error_code,
                description: envelope.description
            )
        }
    }

    private func postMultipartDocument(
        endpoint: String,
        chatID: Int,
        filePath: String,
        caption: String?,
        parseMode: String?
    ) async throws {
        guard !botToken.isEmpty else {
            throw TelegramTransportError.missingBotToken
        }

        guard let requestURL = Self.requestURL(
            apiBaseURL: apiBaseURL,
            botToken: botToken,
            endpoint: endpoint
        ) else {
            throw TelegramTransportError.invalidBaseURL(apiBaseURL.absoluteString)
        }

        let boundary = "nanoclaw-\(UUID().uuidString)"
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        appendMultipartField(name: "chat_id", value: String(chatID), boundary: boundary, into: &body)
        if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendMultipartField(name: "caption", value: caption, boundary: boundary, into: &body)
        }
        if let parseMode, !parseMode.isEmpty {
            appendMultipartField(name: "parse_mode", value: parseMode, boundary: boundary, into: &body)
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let filename = fileURL.lastPathComponent.isEmpty ? "attachment.bin" : fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"document\"; filename=\"\(filename)\"\r\n".data(
                using: .utf8
            )!
        )
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelegramTransportError.invalidHTTPResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            throw TelegramTransportError.httpStatus(
                code: httpResponse.statusCode,
                bodyPreview: bodyPreview(from: responseData)
            )
        }

        if let envelope = try? decoder.decode(APIEnvelope.self, from: responseData),
           envelope.ok == false {
            throw TelegramTransportError.apiRejected(
                code: envelope.error_code,
                description: envelope.description
            )
        }
    }

    private func appendMultipartField(
        name: String,
        value: String,
        boundary: String,
        into body: inout Data
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func bodyPreview(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "<non-utf8>" }
        if text.count <= 240 {
            return text
        }
        let end = text.index(text.startIndex, offsetBy: 240)
        return "\(text[..<end])..."
    }
}

final class TelegramTypingHeartbeat: @unchecked Sendable {
    private let transport: any TelegramTransport
    private let logger: Logger
    private let retryPolicy: TelegramDeliveryRetrier
    private let intervalMs: Int
    private let initialDelayMs: Int

    init(
        transport: any TelegramTransport,
        logger: Logger,
        retryPolicy: TelegramDeliveryRetrier,
        intervalMs: Int,
        initialDelayMs: Int
    ) {
        self.transport = transport
        self.logger = logger
        self.retryPolicy = retryPolicy
        self.intervalMs = max(1, intervalMs)
        self.initialDelayMs = max(0, initialDelayMs)
    }

    func start(chatJID: String) -> Task<Void, Never> {
        let transport = self.transport
        let logger = self.logger
        let retryPolicy = self.retryPolicy
        let intervalMs = self.intervalMs
        let initialDelayMs = self.initialDelayMs

        return Task {
            if initialDelayMs > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(initialDelayMs))
                } catch {
                    return
                }
            }

            logger.debug("Telegram typing heartbeat started for \(chatJID)")
            while !Task.isCancelled {
                if case let .failure(error) = await retryPolicy.sendTyping(chatJID: chatJID, transport: transport) {
                    logger.debug("Telegram typing heartbeat send failed chat=\(chatJID) error=\(error.localizedDescription)")
                }
                do {
                    try await Task.sleep(for: .milliseconds(intervalMs))
                } catch {
                    break
                }
            }
            logger.debug("Telegram typing heartbeat stopped for \(chatJID)")
        }
    }

    func withHeartbeat<T>(
        chatJID: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        let task = start(chatJID: chatJID)
        defer { task.cancel() }
        return try await operation()
    }
}

final class SwiftTelegramOutboundCoordinator: @unchecked Sendable {
    private let store: SQLiteStore
    private let transport: any TelegramTransport
    private let logger: Logger
    private let retryPolicy: TelegramDeliveryRetrier
    private let outboundChannel = "telegram"

    init(
        store: SQLiteStore,
        transport: any TelegramTransport,
        logger: Logger,
        retryPolicy: TelegramDeliveryRetrier
    ) {
        self.store = store
        self.transport = transport
        self.logger = logger
        self.retryPolicy = retryPolicy
    }

    func deliverOnce(maxCount: Int = 10) async throws -> Int {
        let rows = try store.claimOutbound(channel: outboundChannel, maxCount: maxCount)
        guard !rows.isEmpty else { return 0 }

        var deliveredMessageIDs: [String] = []
        deliveredMessageIDs.reserveCapacity(rows.count)

        for row in rows {
            let deliveryResult: Result<Void, Error>
            if row.kind == "attachment", let attachmentPath = row.attachmentPath {
                deliveryResult = await retryPolicy.sendDocument(
                    chatJID: row.chatJID,
                    filePath: attachmentPath,
                    caption: row.caption,
                    transport: transport
                )
            } else {
                deliveryResult = await retryPolicy.sendMessage(
                    chatJID: row.chatJID,
                    text: row.text,
                    transport: transport
                )
            }

            if case .success = deliveryResult {
                deliveredMessageIDs.append(row.id)
            } else {
                if case let .failure(error) = deliveryResult {
                    logger.error(
                        "Swift Telegram delivery failed after retries id=\(row.id) chat=\(row.chatJID) error=\(error.localizedDescription)"
                    )
                } else {
                    logger.error("Swift Telegram delivery failed after retries id=\(row.id) chat=\(row.chatJID)")
                }
            }
        }

        if deliveredMessageIDs.isEmpty {
            return 0
        }

        _ = try store.ackOutbound(messageIDs: deliveredMessageIDs)
        return deliveredMessageIDs.count
    }

    func runPollingLoop(pollIntervalMs: Int, maxCount: Int = 10) async {
        let clampedPoll = max(200, pollIntervalMs)

        while !Task.isCancelled {
            do {
                _ = try await deliverOnce(maxCount: maxCount)
            } catch {
                logger.error("Swift Telegram outbound loop error: \(error.localizedDescription)")
            }

            try? await Task.sleep(for: .milliseconds(clampedPoll))
        }
    }
}
