import Foundation
import GRDB
import Logging
import Testing

@testable import NanoClawHost

private enum SimulatedFailure: Error {
    case boom
}

private struct HostAdapterTestPaths {
    let root: URL
    let dataDir: URL
    let dbPath: String
}

private func makeAdapterTestPaths() throws -> HostAdapterTestPaths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dataDir = root.appendingPathComponent("data")
    let storeDir = root.appendingPathComponent("store")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    let dbPath = storeDir.appendingPathComponent("messages.db").path
    return HostAdapterTestPaths(root: root, dataDir: dataDir, dbPath: dbPath)
}

private func makeAdapterStore(_ paths: HostAdapterTestPaths) throws -> SQLiteStore {
    try SQLiteStore(
        dbPath: paths.dbPath,
        dataDir: paths.dataDir.path,
        logger: Logger(label: "nanoclaw.host.tests.swift-telegram")
    )
}

actor ScriptedTelegramTransport: TelegramTransport {
    private(set) var sentMessages: [(chatJID: String, text: String)] = []
    private(set) var sentDocuments: [(chatJID: String, filePath: String, caption: String?)] = []
    private(set) var sentTyping: [String] = []

    private var failMessageAttemptsRemaining: Int
    private let messageFailure: Error

    init(failMessageAttempts: Int = 0, messageFailure: Error = URLError(.timedOut)) {
        self.failMessageAttemptsRemaining = failMessageAttempts
        self.messageFailure = messageFailure
    }

    func sendMessage(chatJID: String, text: String) async throws {
        sentMessages.append((chatJID: chatJID, text: text))
        if failMessageAttemptsRemaining > 0 {
            failMessageAttemptsRemaining -= 1
            throw messageFailure
        }
    }

    func sendDocument(chatJID: String, filePath: String, caption: String?) async throws {
        sentDocuments.append((chatJID: chatJID, filePath: filePath, caption: caption))
        if failMessageAttemptsRemaining > 0 {
            failMessageAttemptsRemaining -= 1
            throw messageFailure
        }
    }

    func sendTyping(chatJID: String) async throws {
        sentTyping.append(chatJID)
    }
}

@Test
func testTelegramChatIDResolverParsesValidAndRejectsInvalidJIDs() {
    #expect(TelegramChatIDResolver.resolve("telegram_123@direct") == 123)
    #expect(TelegramChatIDResolver.resolve("telegram_-100123@g.us") == -100123)
    #expect(TelegramChatIDResolver.resolve("whatsapp_1@g.us") == nil)
    #expect(TelegramChatIDResolver.resolve("telegram_abc@direct") == nil)
}

@Test
func testTelegramDeliveryRetrierRetriesTransientFailures() async {
    let transport = ScriptedTelegramTransport(failMessageAttempts: 2)
    let retrier = TelegramDeliveryRetrier(maxAttempts: 3, initialBackoffMs: 1, maxBackoffMs: 5)

    let result = await retrier.sendMessage(
        chatJID: "telegram_123@direct",
        text: "hello",
        transport: transport
    )

    if case .failure(let error) = result {
        Issue.record("Expected delivery success, got failure: \(error)")
    }
    let attempts = await transport.sentMessages.count
    #expect(attempts == 3)
}

@Test
func testTelegramDeliveryRetrierStopsAfterMaxAttempts() async {
    let transport = ScriptedTelegramTransport(failMessageAttempts: 10)
    let retrier = TelegramDeliveryRetrier(maxAttempts: 3, initialBackoffMs: 1, maxBackoffMs: 5)

    let result = await retrier.sendMessage(
        chatJID: "telegram_123@direct",
        text: "hello",
        transport: transport
    )

    if case .success = result {
        Issue.record("Expected delivery failure after max attempts")
    }
    let attempts = await transport.sentMessages.count
    #expect(attempts == 3)
}

@Test
func testTelegramDeliveryRetrierSkipsRetryForNonTransientErrors() async {
    let transport = ScriptedTelegramTransport(
        failMessageAttempts: 10,
        messageFailure: URLError(.badURL)
    )
    let retrier = TelegramDeliveryRetrier(maxAttempts: 3, initialBackoffMs: 1, maxBackoffMs: 5)

    let result = await retrier.sendMessage(
        chatJID: "telegram_123@direct",
        text: "hello",
        transport: transport
    )

    if case .success = result {
        Issue.record("Expected non-transient failure without retry")
    }
    let attempts = await transport.sentMessages.count
    #expect(attempts == 1)
}

@Test
func testTelegramDeliveryRetrierSendsTypingAction() async {
    let transport = ScriptedTelegramTransport()
    let retrier = TelegramDeliveryRetrier(maxAttempts: 2, initialBackoffMs: 1, maxBackoffMs: 5)

    let result = await retrier.sendTyping(
        chatJID: "telegram_999@direct",
        transport: transport
    )

    if case .failure(let error) = result {
        Issue.record("Expected typing success, got failure: \(error)")
    }
    let typingCalls = await transport.sentTyping
    #expect(typingCalls == ["telegram_999@direct"])
}

@Test
func testTelegramBotAPITransportRequestURLSupportsTokenWithColon() throws {
    let base = try #require(URL(string: "https://api.telegram.org"))
    let url = try #require(
        TelegramBotAPITransport.requestURL(
            apiBaseURL: base,
            botToken: "123456:ABCdef",
            endpoint: "sendMessage"
        )
    )

    #expect(url.scheme == "https")
    #expect(url.host == "api.telegram.org")
    #expect(url.path == "/bot123456:ABCdef/sendMessage")
}

@Test
func testTelegramBotAPITransportRequestURLPreservesBasePath() throws {
    let base = try #require(URL(string: "https://example.com/api"))
    let url = try #require(
        TelegramBotAPITransport.requestURL(
            apiBaseURL: base,
            botToken: "1:token",
            endpoint: "sendChatAction"
        )
    )

    #expect(url.absoluteString == "https://example.com/api/bot1:token/sendChatAction")
}

@Test
func testTelegramMessageFormatterLeavesPlainTextUnchanged() {
    let formatted = TelegramMessageFormatter.format("hello world")
    #expect(formatted.text == "hello world")
    #expect(formatted.parseMode == nil)
}

@Test
func testTelegramMessageFormatterConvertsMarkdownToHTML() {
    let formatted = TelegramMessageFormatter.format("**Bold** and *italic* and `code`")
    #expect(formatted.parseMode == .html)
    #expect(formatted.text.contains("<b>Bold</b>"))
    #expect(formatted.text.contains("<i>italic</i>"))
    #expect(formatted.text.contains("<code>code</code>"))
}

@Test
func testTelegramMessageFormatterEscapesHTMLOutsideFormattingTags() {
    let formatted = TelegramMessageFormatter.format("**A&B** <unsafe>")
    #expect(formatted.parseMode == .html)
    #expect(formatted.text.contains("<b>A&amp;B</b>"))
    #expect(formatted.text.contains("&lt;unsafe&gt;"))
}

@Test
func testTelegramMessageFormatterDoesNotMutateCronExpression() {
    let cron = "cron: 0 8 * * *"
    let formatted = TelegramMessageFormatter.format(cron)
    #expect(formatted.text == cron)
    #expect(formatted.parseMode == nil)
}

@Test
func testSwiftTelegramOutboundCoordinatorDeliversAndAcksMessages() async throws {
    let paths = try makeAdapterTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = try makeAdapterStore(paths)
    _ = try store.enqueueOutbound(channel: "telegram", chatJID: "telegram_1@direct", text: "one")
    _ = try store.enqueueOutbound(channel: "telegram", chatJID: "telegram_1@direct", text: "two")

    let transport = ScriptedTelegramTransport()
    let coordinator = SwiftTelegramOutboundCoordinator(
        store: store,
        transport: transport,
        logger: Logger(label: "nanoclaw.host.tests.swift-telegram.coordinator"),
        retryPolicy: TelegramDeliveryRetrier(maxAttempts: 2, initialBackoffMs: 1, maxBackoffMs: 5)
    )

    let acked = try await coordinator.deliverOnce(maxCount: 10)
    #expect(acked == 2)

    let claimed = try store.claimOutbound(channel: "telegram", maxCount: 10)
    #expect(claimed.isEmpty)

    let sentCount = await transport.sentMessages.count
    #expect(sentCount == 2)
}

@Test
func testSwiftTelegramOutboundCoordinatorDeliversAndAcksAttachmentMessages() async throws {
    let paths = try makeAdapterTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = try makeAdapterStore(paths)
    let attachment = paths.root.appendingPathComponent("report.txt")
    try "attachment payload".write(to: attachment, atomically: true, encoding: .utf8)

    _ = try store.enqueueOutbound(
        channel: "telegram",
        chatJID: "telegram_1@direct",
        text: "",
        kind: "attachment",
        attachmentPath: attachment.path,
        caption: "Daily report"
    )

    let transport = ScriptedTelegramTransport()
    let coordinator = SwiftTelegramOutboundCoordinator(
        store: store,
        transport: transport,
        logger: Logger(label: "nanoclaw.host.tests.swift-telegram.coordinator"),
        retryPolicy: TelegramDeliveryRetrier(maxAttempts: 2, initialBackoffMs: 1, maxBackoffMs: 5)
    )

    let acked = try await coordinator.deliverOnce(maxCount: 10)
    #expect(acked == 1)

    let sentDocs = await transport.sentDocuments
    #expect(sentDocs.count == 1)
    #expect(sentDocs.first?.filePath == attachment.path)
    #expect(sentDocs.first?.caption == "Daily report")
}

@Test
func testTelegramTypingHeartbeatStartsAfterDelayForLongRunningWork() async throws {
    let transport = ScriptedTelegramTransport()
    let heartbeat = TelegramTypingHeartbeat(
        transport: transport,
        logger: Logger(label: "nanoclaw.host.tests.swift-telegram.typing"),
        retryPolicy: TelegramDeliveryRetrier(maxAttempts: 2, initialBackoffMs: 1, maxBackoffMs: 5),
        intervalMs: 20,
        initialDelayMs: 40
    )

    let task = heartbeat.start(chatJID: "telegram_55@direct")
    defer { task.cancel() }

    try await Task.sleep(for: .milliseconds(20))
    let earlyCalls = await transport.sentTyping.count
    #expect(earlyCalls == 0)

    try await Task.sleep(for: .milliseconds(50))
    let delayedCalls = await transport.sentTyping.count
    #expect(delayedCalls >= 1)
}

@Test
func testTelegramTypingHeartbeatRefreshesWhileProcessing() async throws {
    let transport = ScriptedTelegramTransport()
    let heartbeat = TelegramTypingHeartbeat(
        transport: transport,
        logger: Logger(label: "nanoclaw.host.tests.swift-telegram.typing"),
        retryPolicy: TelegramDeliveryRetrier(maxAttempts: 2, initialBackoffMs: 1, maxBackoffMs: 5),
        intervalMs: 20,
        initialDelayMs: 0
    )

    let task = heartbeat.start(chatJID: "telegram_66@direct")
    defer { task.cancel() }

    try await Task.sleep(for: .milliseconds(70))
    let typingCalls = await transport.sentTyping.count
    #expect(typingCalls >= 3)
}

@Test
func testTelegramTypingHeartbeatStopsAfterManualCancel() async throws {
    let transport = ScriptedTelegramTransport()
    let heartbeat = TelegramTypingHeartbeat(
        transport: transport,
        logger: Logger(label: "nanoclaw.host.tests.swift-telegram.typing"),
        retryPolicy: TelegramDeliveryRetrier(maxAttempts: 2, initialBackoffMs: 1, maxBackoffMs: 5),
        intervalMs: 20,
        initialDelayMs: 0
    )

    let task = heartbeat.start(chatJID: "telegram_77@direct")
    try await Task.sleep(for: .milliseconds(55))
    task.cancel()

    let callsAfterCancel = await transport.sentTyping.count
    try await Task.sleep(for: .milliseconds(60))
    let finalCalls = await transport.sentTyping.count
    #expect(finalCalls == callsAfterCancel)
}

@Test
func testTelegramTypingHeartbeatStopsAfterSuccessOrFailure() async throws {
    let transport = ScriptedTelegramTransport()
    let heartbeat = TelegramTypingHeartbeat(
        transport: transport,
        logger: Logger(label: "nanoclaw.host.tests.swift-telegram.typing"),
        retryPolicy: TelegramDeliveryRetrier(maxAttempts: 2, initialBackoffMs: 1, maxBackoffMs: 5),
        intervalMs: 20,
        initialDelayMs: 0
    )

    let value = try await heartbeat.withHeartbeat(chatJID: "telegram_88@direct") {
        try await Task.sleep(for: .milliseconds(55))
        return "done"
    }
    #expect(value == "done")

    do {
        _ = try await heartbeat.withHeartbeat(chatJID: "telegram_99@direct") {
            try await Task.sleep(for: .milliseconds(55))
            throw SimulatedFailure.boom
        }
        Issue.record("Expected SimulatedFailure.boom to be thrown")
    } catch SimulatedFailure.boom {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let callsAfterCompletion = await transport.sentTyping.count
    try await Task.sleep(for: .milliseconds(60))
    let callsAfterWait = await transport.sentTyping.count
    #expect(callsAfterWait == callsAfterCompletion)
}
