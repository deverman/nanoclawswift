import Foundation
import Logging
import Testing

@testable import NanoClawHost

private final class MockTelegramFileFetcher: TelegramFileFetching, @unchecked Sendable {
    let remotePath: String
    let data: Data

    init(remotePath: String = "photos/test.jpg", data: Data = Data("img".utf8)) {
        self.remotePath = remotePath
        self.data = data
    }

    func resolveFilePath(fileID: String) async throws -> String {
        _ = fileID
        return remotePath
    }

    func downloadFile(filePath: String) async throws -> Data {
        _ = filePath
        return data
    }
}

private struct MockImageTextExtractor: ImageTextExtracting {
    let text: String?

    func extractText(from imagePath: String) async -> String? {
        _ = imagePath
        return text
    }
}

@Test
func testInboundMediaPipelineEnrichesPhotoPlaceholderWithOCR() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let groupsDir = root.appendingPathComponent("groups")
    try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)

    let pipeline = TelegramInboundMediaPipeline(
        groupsDir: groupsDir.path,
        logger: Logger(label: "tests.inbound-media"),
        fetcher: MockTelegramFileFetcher(),
        extractor: MockImageTextExtractor(text: "Total: $42.50")
    )

    let event = InboundEventRequest(
        channel: "telegram",
        chat_jid: "telegram_42@direct",
        sender: "owner",
        sender_name: "Owner",
        content: "[Photo received]",
        timestamp: ISO8601DateFormatter().string(from: Date()),
        message_id: "m-photo-1",
        is_direct: true,
        attachments: [
            InboundAttachment(
                kind: "photo",
                telegramFileID: "file-1",
                telegramFileUniqueID: "uniq-1",
                width: 800,
                height: 600,
                fileSize: 1024,
                mimeType: nil,
                localPath: nil,
                ocrText: nil
            )
        ]
    )

    let enriched = await pipeline.enrich(event: event, groupFolder: "telegram-direct")
    let attachment = try #require(enriched.attachments?.first)
    #expect(attachment.localPath == "/workspace/group/.nanoclaw/inbound-media/m-photo-1-0.jpg")
    #expect(attachment.ocrText == "Total: $42.50")
    #expect(enriched.content.contains("OCR text"))
    #expect(enriched.content.contains("Total: $42.50"))
}

@Test
func testInboundMediaPipelineAppendsOCRForCaptionedPhotoPrompt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let groupsDir = root.appendingPathComponent("groups")
    try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)

    let pipeline = TelegramInboundMediaPipeline(
        groupsDir: groupsDir.path,
        logger: Logger(label: "tests.inbound-media"),
        fetcher: MockTelegramFileFetcher(),
        extractor: MockImageTextExtractor(text: "Invoice #1048")
    )

    let event = InboundEventRequest(
        channel: "telegram",
        chat_jid: "telegram_42@direct",
        sender: "owner",
        sender_name: "Owner",
        content: "What text is in this photo?",
        timestamp: ISO8601DateFormatter().string(from: Date()),
        message_id: "m-photo-3",
        is_direct: true,
        attachments: [
            InboundAttachment(
                kind: "photo",
                telegramFileID: "file-3",
                telegramFileUniqueID: nil,
                width: nil,
                height: nil,
                fileSize: nil,
                mimeType: nil,
                localPath: nil,
                ocrText: nil
            )
        ]
    )

    let enriched = await pipeline.enrich(event: event, groupFolder: "telegram-direct")
    #expect(enriched.content.contains("What text is in this photo?"))
    #expect(enriched.content.contains("OCR text"))
    #expect(enriched.content.contains("Invoice #1048"))
}

@Test
func testInboundMediaPipelineEnrichesPhotoPlaceholderWithSavedPathWhenNoOCR() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let groupsDir = root.appendingPathComponent("groups")
    try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)

    let pipeline = TelegramInboundMediaPipeline(
        groupsDir: groupsDir.path,
        logger: Logger(label: "tests.inbound-media"),
        fetcher: MockTelegramFileFetcher(),
        extractor: MockImageTextExtractor(text: nil)
    )

    let event = InboundEventRequest(
        channel: "telegram",
        chat_jid: "telegram_42@direct",
        sender: "owner",
        sender_name: "Owner",
        content: "[Photo received]",
        timestamp: ISO8601DateFormatter().string(from: Date()),
        message_id: "m-photo-2",
        is_direct: true,
        attachments: [
            InboundAttachment(
                kind: "photo",
                telegramFileID: "file-2",
                telegramFileUniqueID: nil,
                width: nil,
                height: nil,
                fileSize: nil,
                mimeType: nil,
                localPath: nil,
                ocrText: nil
            )
        ]
    )

    let enriched = await pipeline.enrich(event: event, groupFolder: "telegram-direct")
    #expect(enriched.content.contains("saved to /workspace/group/.nanoclaw/inbound-media/m-photo-2-0.jpg"))
}
