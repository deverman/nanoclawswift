import Foundation
import GRDB
import Logging
import Testing

@testable import NanoClawHost

private struct HostTestPaths {
    let root: URL
    let dataDir: URL
    let dbPath: String
}

private func makeHostTestPaths() throws -> HostTestPaths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dataDir = root.appendingPathComponent("data")
    let storeDir = root.appendingPathComponent("store")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    let dbPath = storeDir.appendingPathComponent("messages.db").path
    return HostTestPaths(root: root, dataDir: dataDir, dbPath: dbPath)
}

private func makeStore(_ paths: HostTestPaths) throws -> SQLiteStore {
    try SQLiteStore(
        dbPath: paths.dbPath,
        dataDir: paths.dataDir.path,
        logger: Logger(label: "nanoclaw.host.tests.sqlite")
    )
}

@Test
func testInboundEventDedupe() throws {
    let paths = try makeHostTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = try makeStore(paths)

    let firstInsert = try store.tryInsertInboundEvent(
        channel: "telegram",
        chatJID: "telegram_1@direct",
        messageID: "msg-1"
    )
    let duplicateInsert = try store.tryInsertInboundEvent(
        channel: "telegram",
        chatJID: "telegram_1@direct",
        messageID: "msg-1"
    )
    let differentInsert = try store.tryInsertInboundEvent(
        channel: "telegram",
        chatJID: "telegram_1@direct",
        messageID: "msg-2"
    )

    #expect(firstInsert == true)
    #expect(duplicateInsert == false)
    #expect(differentInsert == true)
}

@Test
func testOutboundClaimAckAndStaleClaimRecovery() throws {
    let paths = try makeHostTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = try makeStore(paths)
    let firstID = try store.enqueueOutbound(channel: "telegram", chatJID: "telegram_1@direct", text: "one")
    let secondID = try store.enqueueOutbound(channel: "telegram", chatJID: "telegram_1@direct", text: "two")

    let firstClaim = try store.claimOutbound(channel: "telegram", maxCount: 1)
    #expect(firstClaim.count == 1)
    #expect(firstClaim.first?.id == firstID)

    let staleSentAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
    let db = try DatabaseQueue(path: paths.dbPath)
    try db.write { db in
        try db.execute(
            sql: "UPDATE outbound_messages SET status = 'claimed', sent_at = ? WHERE id = ?;",
            arguments: [staleSentAt, firstID]
        )
    }

    let secondClaim = try store.claimOutbound(channel: "telegram", maxCount: 10)
    let claimedIDs = Set(secondClaim.map(\.id))
    #expect(claimedIDs.contains(firstID))
    #expect(claimedIDs.contains(secondID))

    let acked = try store.ackOutbound(messageIDs: Array(claimedIDs))
    #expect(acked == claimedIDs.count)
}

@Test
func testLegacyGroupMigrationWithoutAddedAt() throws {
    let paths = try makeHostTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let legacy: [String: Any] = [
        "telegram_1@direct": [
            "name": "Telegram Direct (owner)",
            "folder": "telegram-direct",
            "trigger": "@Andy"
        ]
    ]
    let legacyData = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
    let legacyPath = paths.dataDir.appendingPathComponent("registered_groups.json")
    try legacyData.write(to: legacyPath, options: .atomic)

    let store = try makeStore(paths)
    let group = try store.fetchGroup(jid: "telegram_1@direct")

    #expect(group != nil)
    #expect(group?.folder == "telegram-direct")
    #expect(group?.addedAt.isEmpty == false)
}

@Test
func testScheduledTaskCrud() throws {
    let paths = try makeHostTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = try makeStore(paths)
    let task = ScheduledTaskRow(
        id: "task-1",
        groupFolder: "telegram-direct",
        chatJID: "telegram_1@direct",
        prompt: "Morning Apple report",
        scheduleType: "cron",
        scheduleValue: "0 8 * * *",
        contextMode: "group",
        nextRun: ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)),
        status: "active",
        createdAt: ISO8601DateFormatter().string(from: Date())
    )

    try store.createTask(task)
    let listed = try store.listTasks(for: "telegram-direct", includeAll: false)
    #expect(listed.count == 1)
    #expect(listed.first?.id == "task-1")

    try store.updateTaskStatus(taskID: "task-1", status: "paused")
    let paused = try store.getTask(taskID: "task-1")
    #expect(paused?.status == "paused")

    try store.deleteTask(taskID: "task-1")
    let deleted = try store.getTask(taskID: "task-1")
    #expect(deleted == nil)
}

@Test
func testListGroupsOrdersOwnerDirectGroupsFirstAndHonorsLimit() throws {
    let paths = try makeHostTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }

    let store = try makeStore(paths)
    let now = ISO8601DateFormatter().string(from: Date())

    try store.upsertGroup(
        RegisteredGroupRow(
            jid: "whatsapp_group@g.us",
            name: "WhatsApp Group",
            folder: "wa-group",
            triggerPattern: "@Andy",
            addedAt: now,
            containerConfigJSON: nil,
            requiresTrigger: true
        )
    )

    try store.upsertGroup(
        RegisteredGroupRow(
            jid: "telegram_owner@direct",
            name: "Telegram Direct (owner)",
            folder: "telegram-direct",
            triggerPattern: "@Andy",
            addedAt: now,
            containerConfigJSON: nil,
            requiresTrigger: false
        )
    )

    let groups = try store.listGroups()
    #expect(groups.count == 2)
    #expect(groups.first?.folder == "telegram-direct")

    let limited = try store.listGroups(limit: 1)
    #expect(limited.count == 1)
    #expect(limited.first?.folder == "telegram-direct")
}
