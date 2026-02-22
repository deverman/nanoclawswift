import Testing
@testable import NanoClawHost

@Test
func testCollapseLatestOutboundMessagesKeepsOnlyLatestPerChat() {
    let commands: [NanoClawHostService.IPCMessageCommand] = [
        .init(channel: "telegram", chatJID: "chat-a", text: "first-a", kind: "text", attachmentPath: nil, caption: nil),
        .init(channel: "telegram", chatJID: "chat-b", text: "first-b", kind: "text", attachmentPath: nil, caption: nil),
        .init(channel: "telegram", chatJID: "chat-a", text: "second-a", kind: "text", attachmentPath: nil, caption: nil)
    ]

    let collapsed = NanoClawHostService.collapseLatestOutboundMessages(commands)
    #expect(collapsed.count == 2)
    #expect(collapsed[0].chatJID == "chat-a")
    #expect(collapsed[0].text == "second-a")
    #expect(collapsed[1].chatJID == "chat-b")
    #expect(collapsed[1].text == "first-b")
}

@Test
func testResolveAttachmentHostPathMapsWorkspaceGroupPath() {
    let resolved = NanoClawHostService.resolveAttachmentHostPath(
        containerPath: "/workspace/group/reports/daily.txt",
        sourceGroupFolder: "group-a",
        groupsDir: "/tmp/groups"
    )
    #expect(resolved == "/tmp/groups/group-a/reports/daily.txt")
}

@Test
func testResolveAttachmentHostPathRejectsPathTraversal() {
    let resolved = NanoClawHostService.resolveAttachmentHostPath(
        containerPath: "/workspace/group/../../etc/passwd",
        sourceGroupFolder: "group-a",
        groupsDir: "/tmp/groups"
    )
    #expect(resolved == nil)
}

@Test
func testShouldEnqueueDirectResultWhenNoIPCOutbound() {
    #expect(
        NanoClawHostService.shouldEnqueueDirectResult(
            status: "success",
            result: "Final answer",
            ipcOutboundCount: 0
        )
    )
    #expect(
        !NanoClawHostService.shouldEnqueueDirectResult(
            status: "success",
            result: "Final answer",
            ipcOutboundCount: 2
        )
    )
    #expect(
        !NanoClawHostService.shouldEnqueueDirectResult(
            status: "success",
            result: "   ",
            ipcOutboundCount: 0
        )
    )
}

@Test
func testNormalizedScheduledTaskChatJIDUsesOwnerForTelegramDirectGroup() {
    let resolved = NanoClawHostService.normalizedScheduledTaskChatJID(
        groupFolder: "telegram-direct",
        targetChatJID: "telegram_999@direct",
        ownerDirectChatJID: "telegram_135937217@direct"
    )
    #expect(resolved == "telegram_135937217@direct")
}

@Test
func testNormalizedScheduledTaskChatJIDKeepsTargetForNonDirectGroup() {
    let resolved = NanoClawHostService.normalizedScheduledTaskChatJID(
        groupFolder: "project-ops",
        targetChatJID: "telegram_999@g.us",
        ownerDirectChatJID: "telegram_135937217@direct"
    )
    #expect(resolved == "telegram_999@g.us")
}
