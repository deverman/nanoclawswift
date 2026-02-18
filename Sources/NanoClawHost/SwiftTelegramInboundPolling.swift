import Foundation
import Logging
import SwiftTelegramBot

func normalizedTelegramInboundText(
    text: String?,
    caption: String?,
    hasPhoto: Bool
) -> String? {
    let candidates = [text, caption]
    for candidate in candidates {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
    }

    if hasPhoto {
        return "[Photo received]"
    }
    return nil
}

struct TelegramInboundEnvelope: Sendable {
    let chatID: Int64
    let isDirect: Bool
    let senderID: Int64?
    let senderUsername: String?
    let senderFirstName: String?
    let text: String
    let messageID: Int
    let timestamp: Date
    let attachments: [InboundAttachment]

    init(
        chatID: Int64,
        isDirect: Bool,
        senderID: Int64?,
        senderUsername: String?,
        senderFirstName: String?,
        text: String,
        messageID: Int,
        timestamp: Date,
        attachments: [InboundAttachment] = []
    ) {
        self.chatID = chatID
        self.isDirect = isDirect
        self.senderID = senderID
        self.senderUsername = senderUsername
        self.senderFirstName = senderFirstName
        self.text = text
        self.messageID = messageID
        self.timestamp = timestamp
        self.attachments = attachments
    }
}

struct TelegramInboundEventMapper: Sendable {
    let assistantName: String
    let ownerID: Int64?

    init(assistantName: String, ownerID: Int64?) {
        self.assistantName = assistantName
        self.ownerID = ownerID
    }

    func makeInboundEvent(from envelope: TelegramInboundEnvelope) -> InboundEventRequest? {
        if envelope.isDirect,
           let ownerID,
           envelope.senderID != ownerID {
            return nil
        }

        guard let prompt = triggerPrompt(from: envelope.text, isDirect: envelope.isDirect) else {
            return nil
        }

        let sender = envelope.senderUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderValue: String = {
            if let sender, !sender.isEmpty { return sender }
            if let senderID = envelope.senderID { return "telegram_\(senderID)" }
            return "telegram_\(envelope.chatID)"
        }()

        let senderNameValue: String = {
            if let sender, !sender.isEmpty { return sender }
            if let name = envelope.senderFirstName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            return "unknown"
        }()

        let chatJID = envelope.isDirect
            ? "telegram_\(envelope.chatID)@direct"
            : "telegram_\(envelope.chatID)@g.us"

        return InboundEventRequest(
            channel: "telegram",
            chat_jid: chatJID,
            sender: senderValue,
            sender_name: senderNameValue,
            content: prompt,
            timestamp: isoTimestamp(envelope.timestamp),
            message_id: String(envelope.messageID),
            is_direct: envelope.isDirect,
            attachments: envelope.attachments.isEmpty ? nil : envelope.attachments
        )
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    private func triggerPrompt(from rawText: String, isDirect: Bool) -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if isDirect {
            return text
        }

        let escapedAssistant = NSRegularExpression.escapedPattern(for: assistantName)
        let pattern = "^@\(escapedAssistant)\\b"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        let prompt = text[matchRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }
}

private final class TelegramInboundDispatcher: TGDefaultDispatcher, @unchecked Sendable {
    private let mapper: TelegramInboundEventMapper
    private let onInboundEvent: @Sendable (InboundEventRequest) async -> Void

    init(
        bot: TGBot,
        logger: Logger,
        mapper: TelegramInboundEventMapper,
        onInboundEvent: @escaping @Sendable (InboundEventRequest) async -> Void
    ) {
        self.mapper = mapper
        self.onInboundEvent = onInboundEvent
        super.init(bot: bot, logger: logger)
    }

    override func handle() async {
        await add(TGBaseHandler { [weak self] update in
            guard let self,
                  let envelope = Self.envelope(from: update),
                  let inbound = self.mapper.makeInboundEvent(from: envelope) else {
                return
            }
            await self.onInboundEvent(inbound)
        })
    }

    private static func envelope(from update: TGUpdate) -> TelegramInboundEnvelope? {
        guard let message = update.message else { return nil }
        let photoSizes = message.photo ?? []
        let hasPhoto = !photoSizes.isEmpty
        guard let text = normalizedTelegramInboundText(
            text: message.text,
            caption: message.caption,
            hasPhoto: hasPhoto
        ) else {
            return nil
        }
        let attachments = mapAttachments(from: photoSizes)

        return TelegramInboundEnvelope(
            chatID: message.chat.id,
            isDirect: message.chat.type == .private,
            senderID: message.from?.id,
            senderUsername: message.from?.username,
            senderFirstName: message.from?.firstName,
            text: text,
            messageID: message.messageId,
            timestamp: Date(timeIntervalSince1970: TimeInterval(message.date)),
            attachments: attachments
        )
    }

    private static func mapAttachments(from photos: [TGPhotoSize]) -> [InboundAttachment] {
        guard let largest = photos.max(by: { lhs, rhs in
            let leftSize = lhs.fileSize ?? (lhs.width * lhs.height)
            let rightSize = rhs.fileSize ?? (rhs.width * rhs.height)
            return leftSize < rightSize
        }) else {
            return []
        }
        return [
            InboundAttachment(
                kind: "photo",
                telegramFileID: largest.fileId,
                telegramFileUniqueID: largest.fileUniqueId,
                width: largest.width,
                height: largest.height,
                fileSize: largest.fileSize,
                mimeType: "image/jpeg",
                localPath: nil,
                ocrText: nil
            )
        ]
    }
}

final class SwiftTelegramPollingAdapter: @unchecked Sendable {
    struct Config: Sendable {
        let botToken: String
        let assistantName: String
        let ownerID: Int64?
        let pollLimit: Int?
        let pollTimeoutSec: Int?
    }

    private let bot: TGBot
    private let logger: Logger
    private let dispatcher: TelegramInboundDispatcher
    private var started = false

    init(
        config: Config,
        logger: Logger,
        onInboundEvent: @escaping @Sendable (InboundEventRequest) async -> Void
    ) async throws {
        self.logger = logger
        let mapper = TelegramInboundEventMapper(
            assistantName: config.assistantName,
            ownerID: config.ownerID
        )

        let bot = try await TGBot(
            connectionType: .longpolling(
                limit: config.pollLimit,
                timeout: config.pollTimeoutSec,
                allowedUpdates: [.message]
            ),
            tgClient: TGClientDefault(),
            tgURI: TGBot.standardTGURL,
            botId: config.botToken,
            log: logger
        )
        self.bot = bot
        self.dispatcher = TelegramInboundDispatcher(
            bot: bot,
            logger: logger,
            mapper: mapper,
            onInboundEvent: onInboundEvent
        )
    }

    func start() async throws {
        guard !started else { return }
        try await bot.add(dispatcher: dispatcher)
        _ = try await bot.start()
        started = true
        logger.info("Swift Telegram polling adapter started")
    }

    func stop() async {
        guard started else { return }
        do {
            _ = try await bot.stop()
        } catch {
            logger.error("Swift Telegram polling adapter stop failed: \(error.localizedDescription)")
        }
        started = false
        logger.info("Swift Telegram polling adapter stopped")
    }
}
