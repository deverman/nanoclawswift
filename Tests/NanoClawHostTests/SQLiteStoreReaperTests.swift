import Foundation
import Logging
import Testing

@testable import NanoClawHost

@Test
func testReclaimStaleClaimedOutboundReturnsMessageToPendingQueue() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let dataDir = root.appendingPathComponent("data")
    let storeDir = root.appendingPathComponent("store")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

    let dbPath = storeDir.appendingPathComponent("messages.db").path
    let store = try SQLiteStore(
        dbPath: dbPath,
        dataDir: dataDir.path,
        logger: Logger(label: "nanoclaw.host.tests.sqlite-reaper")
    )

    let messageID = try store.enqueueOutbound(
        channel: "telegram",
        chatJID: "telegram_1@direct",
        text: "hello"
    )
    let claimed = try store.claimOutbound(channel: "telegram", maxCount: 1)
    #expect(claimed.count == 1)
    #expect(claimed.first?.id == messageID)

    Thread.sleep(forTimeInterval: 1.2)
    let reclaimed = try store.reclaimStaleClaimedOutbound(channel: "telegram", olderThanSeconds: 1)
    #expect(reclaimed == 1)

    let reClaimedRows = try store.claimOutbound(channel: "telegram", maxCount: 1)
    #expect(reClaimedRows.count == 1)
    #expect(reClaimedRows.first?.id == messageID)
}
