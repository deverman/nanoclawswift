import Foundation
import Testing

@testable import NanoClawHost

@Test
func testTelegramInboundNormalizedTextUsesCaptionWhenPresent() {
    let normalized = normalizedTelegramInboundText(
        text: nil,
        caption: "  photo with note  ",
        hasPhoto: true
    )
    #expect(normalized == "photo with note")
}

@Test
func testTelegramInboundNormalizedTextSynthesizesPhotoPromptWhenPhotoOnly() {
    let normalized = normalizedTelegramInboundText(
        text: nil,
        caption: nil,
        hasPhoto: true
    )
    #expect(normalized == "[Photo received]")
}

@Test
func testTelegramInboundNormalizedTextReturnsNilWhenNoContentOrPhoto() {
    let normalized = normalizedTelegramInboundText(
        text: "   ",
        caption: nil,
        hasPhoto: false
    )
    #expect(normalized == nil)
}

@Test
func testTelegramInboundMapperBuildsDirectMessageEventForOwner() {
    let mapper = TelegramInboundEventMapper(assistantName: "Andy", ownerID: 42)
    let envelope = TelegramInboundEnvelope(
        chatID: 123456,
        isDirect: true,
        senderID: 42,
        senderUsername: "deverman",
        senderFirstName: "Devin",
        text: "  hello from telegram  ",
        messageID: 9001,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let event = mapper.makeInboundEvent(from: envelope)

    #expect(event?.channel == "telegram")
    #expect(event?.chat_jid == "telegram_123456@direct")
    #expect(event?.sender == "deverman")
    #expect(event?.sender_name == "deverman")
    #expect(event?.content == "hello from telegram")
    #expect(event?.message_id == "9001")
    #expect(event?.is_direct == true)
}

@Test
func testTelegramInboundMapperRejectsUnauthorizedDirectSenderWhenOwnerIsConfigured() {
    let mapper = TelegramInboundEventMapper(assistantName: "Andy", ownerID: 42)
    let envelope = TelegramInboundEnvelope(
        chatID: 123456,
        isDirect: true,
        senderID: 99,
        senderUsername: "someone-else",
        senderFirstName: "Someone",
        text: "hello",
        messageID: 1,
        timestamp: Date()
    )

    let event = mapper.makeInboundEvent(from: envelope)
    #expect(event == nil)
}

@Test
func testTelegramInboundMapperRequiresMentionInGroupChats() {
    let mapper = TelegramInboundEventMapper(assistantName: "Andy", ownerID: nil)
    let envelope = TelegramInboundEnvelope(
        chatID: -10012345,
        isDirect: false,
        senderID: 7,
        senderUsername: nil,
        senderFirstName: "User",
        text: "hello there",
        messageID: 2,
        timestamp: Date()
    )

    let event = mapper.makeInboundEvent(from: envelope)
    #expect(event == nil)
}

@Test
func testTelegramInboundMapperParsesMentionPromptCaseInsensitive() {
    let mapper = TelegramInboundEventMapper(assistantName: "Andy", ownerID: nil)
    let envelope = TelegramInboundEnvelope(
        chatID: -10012345,
        isDirect: false,
        senderID: 7,
        senderUsername: "teammate",
        senderFirstName: "Team",
        text: "@aNdY   summarize this thread",
        messageID: 3,
        timestamp: Date()
    )

    let event = mapper.makeInboundEvent(from: envelope)

    #expect(event?.chat_jid == "telegram_-10012345@g.us")
    #expect(event?.content == "summarize this thread")
    #expect(event?.is_direct == false)
}

@Test
func testTelegramInboundMapperRejectsMentionWithoutPrompt() {
    let mapper = TelegramInboundEventMapper(assistantName: "Andy", ownerID: nil)
    let envelope = TelegramInboundEnvelope(
        chatID: -10012345,
        isDirect: false,
        senderID: 7,
        senderUsername: nil,
        senderFirstName: "User",
        text: "@Andy   ",
        messageID: 4,
        timestamp: Date()
    )

    let event = mapper.makeInboundEvent(from: envelope)
    #expect(event == nil)
}

@Test
func testTelegramInboundMapperRejectsPartialPrefixMention() {
    let mapper = TelegramInboundEventMapper(assistantName: "Andy", ownerID: nil)
    let envelope = TelegramInboundEnvelope(
        chatID: -10012345,
        isDirect: false,
        senderID: 7,
        senderUsername: nil,
        senderFirstName: "User",
        text: "@andyman can you help?",
        messageID: 5,
        timestamp: Date()
    )

    let event = mapper.makeInboundEvent(from: envelope)
    #expect(event == nil)
}

@Test
func testTelegramInboundMapperPreservesPhotoAttachmentMetadata() {
    let mapper = TelegramInboundEventMapper(assistantName: "Andy", ownerID: 42)
    let envelope = TelegramInboundEnvelope(
        chatID: 123456,
        isDirect: true,
        senderID: 42,
        senderUsername: "deverman",
        senderFirstName: "Devin",
        text: "[Photo received]",
        messageID: 9002,
        timestamp: Date(timeIntervalSince1970: 1_700_000_100),
        attachments: [
            InboundAttachment(
                kind: "photo",
                telegramFileID: "file-1",
                telegramFileUniqueID: "uniq-1",
                width: 1024,
                height: 768,
                fileSize: 2048,
                mimeType: nil,
                localPath: nil,
                ocrText: nil
            )
        ]
    )

    let event = mapper.makeInboundEvent(from: envelope)
    let attachment = try? #require(event?.attachments?.first)
    #expect(attachment?.kind == "photo")
    #expect(attachment?.telegramFileID == "file-1")
}
