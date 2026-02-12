import Foundation
import Logging
import Testing

@testable import NanoClawHost

private actor QueueProbe {
    private var inFlightGroups: Set<String> = []
    private(set) var maxConcurrentGroups = 0
    private var orderByGroup: [String: [String]] = [:]
    private(set) var processedCount = 0

    func begin(groupFolder: String, requestID: String) {
        inFlightGroups.insert(groupFolder)
        maxConcurrentGroups = max(maxConcurrentGroups, inFlightGroups.count)
        orderByGroup[groupFolder, default: []].append(requestID)
    }

    func end(groupFolder: String) {
        inFlightGroups.remove(groupFolder)
        processedCount += 1
    }

    func order(for groupFolder: String) -> [String] {
        orderByGroup[groupFolder, default: []]
    }
}

private func makeGroup(_ folder: String) -> RegisteredGroupRow {
    RegisteredGroupRow(
        jid: "telegram_\(folder)@direct",
        name: "Group \(folder)",
        folder: folder,
        triggerPattern: "@Andy",
        addedAt: ISO8601DateFormatter().string(from: Date()),
        containerConfigJSON: nil,
        requiresTrigger: false
    )
}

private func makeJob(requestID: String, groupFolder: String) -> QueueJob {
    QueueJob(
        requestID: requestID,
        channel: "telegram",
        chatJID: "telegram_\(groupFolder)@direct",
        sender: "tester",
        senderName: "tester",
        content: "test",
        timestamp: ISO8601DateFormatter().string(from: Date()),
        messageID: requestID,
        group: makeGroup(groupFolder),
        isScheduledTask: false,
        scheduledTaskID: nil,
        contextMode: "group",
        enqueuedAt: Date()
    )
}

@Test
func testGroupQueueSerializesPerGroupAndHonorsGlobalConcurrency() async throws {
    let probe = QueueProbe()
    let queue = GroupQueue(
        maxConcurrentGroups: 2,
        logger: Logger(label: "nanoclaw.host.tests.queue")
    ) { job in
        await probe.begin(groupFolder: job.group.folder, requestID: job.requestID)
        let sleepMs = job.group.folder == "group-a" ? 40 : 60
        try? await Task.sleep(for: .milliseconds(sleepMs))
        await probe.end(groupFolder: job.group.folder)
    }

    await queue.enqueue(makeJob(requestID: "a-1", groupFolder: "group-a"))
    await queue.enqueue(makeJob(requestID: "a-2", groupFolder: "group-a"))
    await queue.enqueue(makeJob(requestID: "a-3", groupFolder: "group-a"))
    await queue.enqueue(makeJob(requestID: "b-1", groupFolder: "group-b"))
    await queue.enqueue(makeJob(requestID: "c-1", groupFolder: "group-c"))

    let expectedCount = 5
    let timeout = Date().addingTimeInterval(5)
    while await probe.processedCount < expectedCount, Date() < timeout {
        try? await Task.sleep(for: .milliseconds(25))
    }

    #expect(await probe.processedCount == expectedCount)
    #expect(await probe.maxConcurrentGroups <= 2)
    #expect(await probe.order(for: "group-a") == ["a-1", "a-2", "a-3"])
}
