import Testing

@testable import NanoClawHost

@Test
func testRequiresPreRunTaskSnapshotForTaskPrompts() {
    #expect(NanoClawHostService.requiresPreRunTaskSnapshot(for: "list tasks"))
    #expect(NanoClawHostService.requiresPreRunTaskSnapshot(for: "Please schedule task every day at 8"))
    #expect(NanoClawHostService.requiresPreRunTaskSnapshot(for: "what is scheduled?"))
    #expect(NanoClawHostService.requiresPreRunTaskSnapshot(for: "pause task abc123"))
}

@Test
func testRequiresPreRunTaskSnapshotFalseForNonTaskPrompts() {
    #expect(!NanoClawHostService.requiresPreRunTaskSnapshot(for: "Please use the list_skills tool"))
    #expect(!NanoClawHostService.requiresPreRunTaskSnapshot(for: "Please activate skill focus-mode"))
    #expect(!NanoClawHostService.requiresPreRunTaskSnapshot(for: "what tools do you have?"))
}

@Test
func testSchedulableDueTasksSkipsRunningTaskIDs() {
    let due = [
        ScheduledTaskRow(
            id: "task-1",
            groupFolder: "telegram-direct",
            chatJID: "telegram_1@direct",
            prompt: "p1",
            scheduleType: "cron",
            scheduleValue: "0 8 * * *",
            contextMode: "group",
            nextRun: "2026-02-16T00:00:00Z",
            status: "active",
            createdAt: "2026-02-16T00:00:00Z"
        ),
        ScheduledTaskRow(
            id: "task-2",
            groupFolder: "telegram-direct",
            chatJID: "telegram_1@direct",
            prompt: "p2",
            scheduleType: "cron",
            scheduleValue: "30 8 * * *",
            contextMode: "group",
            nextRun: "2026-02-16T00:30:00Z",
            status: "active",
            createdAt: "2026-02-16T00:00:00Z"
        )
    ]

    let filtered = NanoClawHostService.schedulableDueTasks(
        from: due,
        runningIDs: ["task-1"]
    )
    #expect(filtered.count == 1)
    #expect(filtered.first?.id == "task-2")
}

@Test
func testStartupCatchUpNoticeIncludesTaskAndSummary() {
    let notice = NanoClawHostService.startupCatchUpNotice(
        taskID: "task-123",
        prompt: "Search for latest Apple news and send morning report"
    )
    #expect(notice.contains("offline earlier"))
    #expect(notice.contains("task-123"))
    #expect(notice.contains("Search for latest Apple news"))
}
