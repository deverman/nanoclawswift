import Foundation
import GRDB
import Logging
import Testing

@testable import NanoClawHost

private struct TelegramCommandTestPaths {
    let root: URL
    let dataDir: URL
    let storeDir: URL
    let groupsDir: URL
    let dbPath: String
}

private func makeTelegramCommandTestPaths() throws -> TelegramCommandTestPaths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dataDir = root.appendingPathComponent("data")
    let storeDir = root.appendingPathComponent("store")
    let groupsDir = root.appendingPathComponent("groups")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)
    let dbPath = storeDir.appendingPathComponent("messages.db").path
    return TelegramCommandTestPaths(
        root: root,
        dataDir: dataDir,
        storeDir: storeDir,
        groupsDir: groupsDir,
        dbPath: dbPath
    )
}

private func makeTelegramCommandService(
    paths: TelegramCommandTestPaths,
    ownerID: String? = nil
) throws -> NanoClawHostService {
    var environment: [String: String] = [
        "ASSISTANT_NAME": "Andy",
        "NANOCLAW_PREWARM_GROUP_SESSIONS": "false",
        "NANOCLAW_WORKING_ACK_ENABLED": "false"
    ]
    if let ownerID {
        environment["TELEGRAM_OWNER_ID"] = ownerID
    }
    let hostEnvironment = HostEnvironmentConfig.load(from: environment)
    let runtimeConfig = HostRuntimeConfig(
        projectRoot: paths.root.path,
        groupsDir: paths.groupsDir.path,
        storeDir: paths.storeDir.path,
        containerImage: "nanoclawswift-agent:slim",
        containerTimeoutMs: 1_000,
        containerPollMs: 25,
        queueJobWatchdogMs: 1_000,
        sessionJanitorIntervalSec: 30,
        staleClaimReapAgeSec: 180,
        containerPassthroughEnvironment: [:]
    )

    return try NanoClawHostService(
        logger: Logger(label: "nanoclaw.host.tests.telegram-commands"),
        assistantName: "Andy",
        hostEnvironment: hostEnvironment,
        runtimeConfig: runtimeConfig,
        dataDir: paths.dataDir.path,
        databasePath: paths.dbPath,
        maxConcurrentGroups: 1,
        telegramTransport: nil
    )
}

private func makeInboundEvent(
    content: String,
    messageID: String,
    attachments: [InboundAttachment]? = nil,
    chatJID: String = "telegram_42@direct"
) -> InboundEventRequest {
    InboundEventRequest(
        channel: "telegram",
        chat_jid: chatJID,
        sender: "owner",
        sender_name: "owner",
        content: content,
        timestamp: ISO8601DateFormatter().string(from: Date()),
        message_id: messageID,
        is_direct: true,
        attachments: attachments
    )
}

private func claimOutboundMessages(_ service: NanoClawHostService) async throws -> [OutboundMessageDTO] {
    let payload = OutboundClaimRequest(channel: "telegram", max_count: 50)
    let body = try JSONEncoder().encode(payload)
    let request = HTTPRequest(
        method: "POST",
        path: "/v1/outbound/claim",
        headers: ["Content-Type": "application/json"],
        body: body
    )
    let response = await service.handleRequest(request)
    #expect(response.statusCode == 200)
    let decoded = try JSONDecoder().decode(OutboundClaimResponse.self, from: response.body)
    return decoded.messages
}

private func fetchTaskRows(dbPath: String) throws -> [(id: String, chatJID: String, status: String, scheduleType: String, scheduleValue: String)] {
    let db = try DatabaseQueue(path: dbPath)
    return try db.read { db in
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, chat_jid, status, schedule_type, schedule_value
            FROM scheduled_tasks
            ORDER BY created_at DESC;
            """
        )
        return rows.map { row in
            (
                id: row["id"],
                chatJID: row["chat_jid"],
                status: row["status"],
                scheduleType: row["schedule_type"],
                scheduleValue: row["schedule_value"]
            )
        }
    }
}

@Test
func testTelegramDirectScheduleBindsTaskToOwnerChatWhenConfigured() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths, ownerID: "135937217")

    _ = await service.ingestInboundEvent(
        makeInboundEvent(
            content: "/schedule 08:30 Review inbox",
            messageID: "m-owner-bind",
            chatJID: "telegram_42@direct"
        )
    )

    let createdTasks = try fetchTaskRows(dbPath: paths.dbPath)
    #expect(createdTasks.count == 1)
    let createdTask = try #require(createdTasks.first)
    #expect(createdTask.chatJID == "telegram_135937217@direct")
}

@Test
func testTelegramDirectScheduleListPauseResumeCancelCommands() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths)

    _ = await service.ingestInboundEvent(makeInboundEvent(content: "/schedule 08:30 Review inbox", messageID: "m1"))

    let createdTasks = try fetchTaskRows(dbPath: paths.dbPath)
    #expect(createdTasks.count == 1)
    let createdTask = try #require(createdTasks.first)
    #expect(createdTask.scheduleType == "cron")
    #expect(createdTask.scheduleValue == "30 8 * * *")
    let taskID = createdTask.id

    _ = await service.ingestInboundEvent(makeInboundEvent(content: "/tasks", messageID: "m2"))
    _ = await service.ingestInboundEvent(makeInboundEvent(content: "/pause \(taskID)", messageID: "m3"))
    _ = await service.ingestInboundEvent(makeInboundEvent(content: "/resume \(taskID)", messageID: "m4"))
    _ = await service.ingestInboundEvent(makeInboundEvent(content: "/cancel \(taskID)", messageID: "m5"))

    let rowsAfterCancel = try fetchTaskRows(dbPath: paths.dbPath)
    #expect(rowsAfterCancel.isEmpty)

    let outbound = try await claimOutboundMessages(service)
    let outboundText = outbound.map(\ .text).joined(separator: "\n")
    #expect(outboundText.contains("Scheduled task"))
    #expect(outboundText.contains(taskID))
    #expect(outboundText.contains("Paused task"))
    #expect(outboundText.contains("Resumed task"))
    #expect(outboundText.contains("Canceled task"))
}

@Test
func testTelegramDirectTasksCommandReturnsEmptyState() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths)

    _ = await service.ingestInboundEvent(makeInboundEvent(content: "/tasks", messageID: "m1"))
    let outbound = try await claimOutboundMessages(service)

    #expect(outbound.count == 1)
    let first = try #require(outbound.first)
    #expect(first.text.contains("No scheduled tasks"))
}

@Test
func testTelegramDirectScheduleCommandRejectsInvalidInputWithUsageHint() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths)

    _ = await service.ingestInboundEvent(makeInboundEvent(content: "/schedule tomorrow", messageID: "m1"))
    let outbound = try await claimOutboundMessages(service)

    #expect(outbound.count == 1)
    let first = try #require(outbound.first)
    #expect(first.text.contains("Usage"))
}

@Test
func testTelegramDirectNaturalLanguageTaskCommandsAreNotIntercepted() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths)

    let response = await service.ingestInboundEvent(
        makeInboundEvent(content: "what is scheduled?", messageID: "m1")
    )

    #expect(response.accepted == true)
    #expect(response.request_id != nil)
}

@Test
func testTelegramDirectInterceptionBoundaryTasksVsSkills() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths)

    let tasksResponse = await service.ingestInboundEvent(
        makeInboundEvent(content: "/tasks", messageID: "m1")
    )
    #expect(tasksResponse.accepted == true)
    #expect(tasksResponse.request_id == nil)

    let tasksOutbound = try await claimOutboundMessages(service)
    #expect(tasksOutbound.count == 1)
    #expect(tasksOutbound[0].text.contains("No scheduled tasks"))

    let skillsResponse = await service.ingestInboundEvent(
        makeInboundEvent(content: "/skills", messageID: "m2")
    )
    #expect(skillsResponse.accepted == true)
    #expect(skillsResponse.request_id != nil)
}

@Test
func testTelegramDirectOCRQueryReturnsDeterministicTextOnlyResponse() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths)
    let attachment = InboundAttachment(
        kind: "photo",
        telegramFileID: "file-ocr-1",
        telegramFileUniqueID: nil,
        width: 1200,
        height: 800,
        fileSize: 42_000,
        mimeType: "image/jpeg",
        localPath: "/workspace/group/.nanoclaw/inbound-media/ocr-1.jpg",
        ocrText: "4 Tampines Central 5, #01-\n46, Singapore 529510\nJohns Hopkins Heart and Stroke Walk 20|1"
    )

    _ = await service.ingestInboundEvent(
        makeInboundEvent(
            content: "What is the text in this photo?",
            messageID: "ocr1",
            attachments: [attachment]
        )
    )

    let outbound = try await claimOutboundMessages(service)
    #expect(outbound.count == 1)
    let response = try #require(outbound.first?.text)
    #expect(response.contains("Detected text:"))
    #expect(response.contains("Confidence: Medium"))
    #expect(response.contains("Potential corrections:"))
    #expect(response.contains("20|1"))
    #expect(response.contains("#01-46"))
    #expect(!response.contains("Image path:"))
    #expect(!response.contains("appears to be"))
}

@Test
func testTelegramDirectOCRQueryHandlesMissingExtractedTextGracefully() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths)
    let attachment = InboundAttachment(
        kind: "photo",
        telegramFileID: "file-ocr-2",
        telegramFileUniqueID: nil,
        width: 1200,
        height: 800,
        fileSize: 42_000,
        mimeType: "image/jpeg",
        localPath: "/workspace/group/.nanoclaw/inbound-media/ocr-2.jpg",
        ocrText: nil
    )

    _ = await service.ingestInboundEvent(
        makeInboundEvent(
            content: "please extract text from this image",
            messageID: "ocr2",
            attachments: [attachment]
        )
    )

    let outbound = try await claimOutboundMessages(service)
    #expect(outbound.count == 1)
    let response = try #require(outbound.first?.text)
    #expect(response.contains("Detected text:"))
    #expect(response.contains("none"))
    #expect(response.contains("Confidence: Low"))
    #expect(response.contains("Image path"))
    #expect(response.contains("Please send a closer, well-lit photo"))
}

@Test
func testTelegramDirectOCRQueryIncludesImagePathWhenUserAsksDebugDetails() async throws {
    let paths = try makeTelegramCommandTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let service = try makeTelegramCommandService(paths: paths)
    let attachment = InboundAttachment(
        kind: "photo",
        telegramFileID: "file-ocr-3",
        telegramFileUniqueID: nil,
        width: 1200,
        height: 800,
        fileSize: 42_000,
        mimeType: "image/jpeg",
        localPath: "/workspace/group/.nanoclaw/inbound-media/ocr-3.jpg",
        ocrText: "Sample text"
    )

    _ = await service.ingestInboundEvent(
        makeInboundEvent(
            content: "What text is in this photo? include debug path",
            messageID: "ocr3",
            attachments: [attachment]
        )
    )

    let outbound = try await claimOutboundMessages(service)
    #expect(outbound.count == 1)
    let response = try #require(outbound.first?.text)
    #expect(response.contains("Image path: /workspace/group/.nanoclaw/inbound-media/ocr-3.jpg"))
}
