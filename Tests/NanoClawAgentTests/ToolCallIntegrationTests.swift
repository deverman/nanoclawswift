import Testing
import Foundation
import SwiftAgents
@testable import NanoClawAgent

actor ToolCallRecorder {
    private(set) var called = false
    private(set) var lastValue: String?

    func record(_ value: String) {
        called = true
        lastValue = value
    }
}

struct EchoTool: Tool {
    let name = "echo"
    let description = "Echoes back provided text"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "text", description: "Text to echo", type: .string)
    ]

    let recorder: ToolCallRecorder

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let text = arguments["text"]?.stringValue ?? ""
        await recorder.record(text)
        return .string(text)
    }
}

actor SequencedInferenceProvider: InferenceProvider {
    private var step = 0
    private var toolCallGenerateCount = 0
    private let outputs: [InferenceResponse]

    init(outputs: [InferenceResponse]) {
        self.outputs = outputs
    }

    func generate(prompt: String, options: InferenceOptions) async throws -> String {
        "final"
    }

    nonisolated func stream(prompt: String, options: InferenceOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("final")
            continuation.finish()
        }
    }

    func generateWithToolCalls(
        prompt: String,
        tools: [ToolDefinition],
        options: InferenceOptions
    ) async throws -> InferenceResponse {
        toolCallGenerateCount += 1
        let index = step
        step += 1
        if index < outputs.count {
            return outputs[index]
        }
        return InferenceResponse(content: "final", finishReason: .completed)
    }

    func getToolCallGenerateCount() -> Int {
        toolCallGenerateCount
    }
}

struct SkillsProbeTool: Tool {
    let name = "list_skills"
    let description = "Lists skills for test coverage"
    let parameters: [ToolParameter] = []
    let output: String

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        .string(output)
    }
}

struct MCPStatusProbeTool: Tool {
    let name = "mcp_status"
    let description = "Returns MCP runtime status for tests"
    let parameters: [ToolParameter] = []
    let output: String

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        .string(output)
    }
}

struct FocusRelayInboxProbeTool: Tool {
    let name = "focusrelay_inbox_tasks"
    let description = "Returns FocusRelay inbox payload for tests"
    let parameters: [ToolParameter] = []
    let output: String

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        .string(output)
    }
}

struct FocusRelayCLIProbeTool: Tool {
    let name = "focusrelay_cli"
    let description = "Returns FocusRelay CLI payload for tests"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "subcommand", description: "subcommand", type: .string),
        ToolParameter(name: "args", description: "args", type: .array(elementType: .string), isRequired: false)
    ]
    let output: String

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        _ = arguments
        return .string(output)
    }
}

struct MCPHostCLIProbeTool: Tool {
    let name = "mcp_host_cli"
    let description = "Returns host MCP CLI payload for tests"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "server_id", description: "server", type: .string),
        ToolParameter(name: "args", description: "args", type: .array(elementType: .string), isRequired: false)
    ]
    let output: String

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        _ = arguments
        return .string(output)
    }
}

actor MCPHostCLISequenceRecorder {
    private(set) var callArguments: [[String: SendableValue]] = []
    private var outputs: [String]

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func nextOutput(arguments: [String: SendableValue]) -> String {
        callArguments.append(arguments)
        if outputs.isEmpty {
            return #"{"items":[]}"#
        }
        return outputs.removeFirst()
    }
}

struct MCPHostCLISequencedTool: Tool {
    let name = "mcp_host_cli"
    let description = "Returns sequenced host MCP CLI payloads for pagination tests"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "server_id", description: "server", type: .string),
        ToolParameter(name: "args", description: "args", type: .array(elementType: .string), isRequired: false)
    ]
    let recorder: MCPHostCLISequenceRecorder

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let output = await recorder.nextOutput(arguments: arguments)
        return .string(output)
    }
}

struct MCPBridgedListTasksProbeTool: Tool {
    let name = "mcp_focusrelay_list_tasks"
    let description = "Returns bridged MCP list-tasks payload for tests"
    let parameters: [ToolParameter] = []
    let output: String

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        _ = arguments
        return .string(output)
    }
}

struct MCPReloadProbeTool: Tool {
    let name = "mcp_reload"
    let description = "Reloads MCP runtime config for tests"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "config_path", description: "optional config path", type: .string, isRequired: false)
    ]
    let output: String

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        _ = arguments
        return .string(output)
    }
}

@Test
func testExplicitListSkillsBypassesInferenceProviderLoop() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [SkillsProbeTool(output: "skills-ok")],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("/skills")
    #expect(result.output == "skills-ok")
    #expect(result.metadata["nanoclaw.explicit_tool_mode"]?.boolValue == true)

    let toolCallGenerateCount = await provider.getToolCallGenerateCount()
    #expect(toolCallGenerateCount == 0)
}

@Test
func testExplicitMCPStatusBypassesInferenceProviderLoop() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPStatusProbeTool(output: "mcp-ok")],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("/mcp-status")
    #expect(result.output == "mcp-ok")
    #expect(result.metadata["nanoclaw.explicit_tool_mode"]?.boolValue == true)

    let toolCallGenerateCount = await provider.getToolCallGenerateCount()
    #expect(toolCallGenerateCount == 0)
}

@Test
func testExplicitMCPHostCLIInvocationBypassesInferenceProviderLoop() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLIProbeTool(output: "host-cli-ok")],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("/mcp-cli focusrelay list-tasks --inbox-only true")
    #expect(result.output == "host-cli-ok")
    #expect(result.metadata["nanoclaw.explicit_tool_mode"]?.boolValue == true)

    let toolCallGenerateCount = await provider.getToolCallGenerateCount()
    #expect(toolCallGenerateCount == 0)
}

@Test
func testExplicitMCPReloadBypassesInferenceProviderLoop() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPReloadProbeTool(output: "reload-ok")],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("/mcp-reload")
    #expect(result.output == "reload-ok")
    #expect(result.metadata["nanoclaw.explicit_tool_mode"]?.boolValue == true)

    let toolCallGenerateCount = await provider.getToolCallGenerateCount()
    #expect(toolCallGenerateCount == 0)
}

@Test
func testExplicitMCPReloadWithConfigPathBypassesInferenceProviderLoop() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPReloadProbeTool(output: "reload-path-ok")],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("/mcp-reload /workspace/group/.mcp.json")
    #expect(result.output == "reload-path-ok")
    #expect(result.metadata["nanoclaw.explicit_tool_mode"]?.boolValue == true)

    let toolCallGenerateCount = await provider.getToolCallGenerateCount()
    #expect(toolCallGenerateCount == 0)
}

@Test
func testExplicitMCPHostCLIRendersFriendlyOutputForJSON() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let jsonOutput = #"{"nextCursor":"1","items":[{"name":"Inbox Task","id":"t1"}]}"#
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLIProbeTool(output: jsonOutput)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("/mcp-cli focusrelay list-tasks --inbox-only true")
    #expect(result.metadata["nanoclaw.explicit_tool_mode"]?.boolValue == true)
    #expect(result.output.contains("Found 1 item(s):"))
    #expect(result.output.contains("1. Inbox Task (id: t1)"))
    #expect(result.output.contains("Next cursor: 1"))

    let toolCallGenerateCount = await provider.getToolCallGenerateCount()
    #expect(toolCallGenerateCount == 0)
}

@Test
func testExplicitMCPHostCLIPaginationAddsSlashMoreHint() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let jsonOutput = #"{"nextCursor":"5","items":[{"name":"Inbox Task","id":"t1"}]}"#
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLIProbeTool(output: jsonOutput)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("/mcp-cli focusrelay list-tasks --inbox-only true --limit 5")
    #expect(result.output.contains("Next cursor: 5"))
    #expect(result.output.contains("/more"))
    #expect(result.output.contains("/more <n>"))
}

@Test
func testSlashMoreReusesLastMCPHostCLIInvocationWithCursor() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let recorder = MCPHostCLISequenceRecorder(outputs: [
        #"{"nextCursor":"5","items":[{"name":"Task 1","id":"t1"}]}"#,
        #"{"nextCursor":"10","items":[{"name":"Task 2","id":"t2"}]}"#
    ])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLISequencedTool(recorder: recorder)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    _ = try await agent.run("/mcp-cli focusrelay list-tasks --inbox-only true --limit 5")
    let second = try await agent.run("/more")
    #expect(second.output.contains("Task 2"))

    let calls = await recorder.callArguments
    #expect(calls.count == 2)
    #expect(calls[1]["server_id"]?.stringValue == "focusrelay")
    let secondArgs = calls[1]["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(secondArgs.contains("--cursor"))
    #expect(secondArgs.contains("5"))
}

@Test
func testSlashMoreWithExplicitLimitOverridesPaginationLimit() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let recorder = MCPHostCLISequenceRecorder(outputs: [
        #"{"nextCursor":"5","items":[{"name":"Task 1","id":"t1"}]}"#,
        #"{"nextCursor":"7","items":[{"name":"Task 2","id":"t2"},{"name":"Task 3","id":"t3"}]}"#
    ])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLISequencedTool(recorder: recorder)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    _ = try await agent.run("/mcp-cli focusrelay list-tasks --inbox-only true --limit 5")
    let second = try await agent.run("/more 2")
    #expect(second.output.contains("Found 2 item(s):"))

    let calls = await recorder.callArguments
    #expect(calls.count == 2)
    let secondArgs = calls[1]["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(secondArgs.contains("--cursor"))
    #expect(secondArgs.contains("5"))
    #expect(secondArgs.contains("--limit"))
    #expect(secondArgs.contains("2"))
}

@Test
func testSlashMoreWithoutPreviousPaginationReturnsHelpfulMessage() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLIProbeTool(output: #"{"items":[]}"#)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("/more")
    #expect(result.output.contains("No paginated MCP result"))
}

@Test
func testSlashMoreAfterEmptyNextPageReturnsNoAdditionalItemsMessage() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let recorder = MCPHostCLISequenceRecorder(outputs: [
        #"{"nextCursor":"5","items":[{"name":"Task 1","id":"t1"}]}"#,
        #"{"items":[]}"#
    ])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLISequencedTool(recorder: recorder)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    _ = try await agent.run("/mcp-cli focusrelay list-tasks --inbox-only true --limit 5")
    let firstMore = try await agent.run("/more")
    #expect(firstMore.output.contains("No additional items were returned"))
    let secondMore = try await agent.run("/more")
    #expect(secondMore.output.contains("No additional items were returned"))
}

@Test
func testSlashMoreAfterCursorPageWithoutNextCursorReturnsNoAdditionalItemsMessage() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let recorder = MCPHostCLISequenceRecorder(outputs: [
        #"{"nextCursor":"5","items":[{"name":"Task 1","id":"t1"}]}"#,
        #"{"items":[{"name":"Task 2","id":"t2"}]}"#
    ])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLISequencedTool(recorder: recorder)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    _ = try await agent.run("/mcp-cli focusrelay list-tasks --inbox-only true --limit 5")
    let firstMore = try await agent.run("/more")
    #expect(firstMore.output.contains("Task 2"))
    let secondMore = try await agent.run("/more")
    #expect(secondMore.output.contains("No additional items were returned"))
}

@Test
func testShowMorePhraseDoesNotTriggerDeterministicPaginationPath() async throws {
    let provider = SequencedInferenceProvider(outputs: [
        InferenceResponse(content: "model-path", finishReason: .completed),
        InferenceResponse(content: "model-path", finishReason: .completed)
    ])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLIProbeTool(output: #"{"nextCursor":"5","items":[{"name":"Task 1","id":"t1"}]}"#)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("show more")
    #expect(result.metadata["nanoclaw.execution_route"]?.stringValue == ExecutionRoute.planAndExecute.rawValue)
    #expect(result.metadata["nanoclaw.explicit_tool_mode"]?.boolValue != true)
}

@Test
func testSlashMoreRecoversFromEmptyCursorPageUsingExpandedLimitFallback() async throws {
    let provider = SequencedInferenceProvider(outputs: [])
    let recorder = MCPHostCLISequenceRecorder(outputs: [
        #"""
        {"nextCursor":"5","items":[
            {"name":"Task 1","id":"t1"},
            {"name":"Task 2","id":"t2"},
            {"name":"Task 3","id":"t3"},
            {"name":"Task 4","id":"t4"},
            {"name":"Task 5","id":"t5"}
        ]}
        """#,
        #"{"items":[]}"#,
        #"""
        {"items":[
            {"name":"Task 1","id":"t1"},
            {"name":"Task 2","id":"t2"},
            {"name":"Task 3","id":"t3"},
            {"name":"Task 4","id":"t4"},
            {"name":"Task 5","id":"t5"},
            {"name":"Task 6","id":"t6"},
            {"name":"Task 7","id":"t7"},
            {"name":"Task 8","id":"t8"}
        ]}
        """#
    ])
    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [MCPHostCLISequencedTool(recorder: recorder)],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    _ = try await agent.run("/mcp-cli focusrelay list-tasks --inbox-only true --limit 5")
    let second = try await agent.run("/more")
    #expect(second.output.contains("Found 3 item(s):"))
    #expect(second.output.contains("Task 6"))
    #expect(second.output.contains("Task 8"))
    #expect(!second.output.contains("No additional items were returned"))

    let calls = await recorder.callArguments
    #expect(calls.count == 3)

    let secondArgs = calls[1]["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(secondArgs.contains("--cursor"))
    #expect(secondArgs.contains("5"))

    let thirdArgs = calls[2]["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(!thirdArgs.contains("--cursor"))
    #expect(thirdArgs.contains("--limit"))
    #expect(thirdArgs.contains("10"))
}

@Test
func testStructuredScheduleAndCancelPersistIPCRequests() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ipcDir = tempDir.appendingPathComponent("ipc")
    let tasksDir = ipcDir.appendingPathComponent("tasks")
    try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let snapshot: [[String: Any]] = [[
        "id": "task-123",
        "groupFolder": "test-group",
        "status": "active",
        "prompt": "Morning report"
    ]]
    let snapshotData = try JSONSerialization.data(withJSONObject: snapshot)
    try snapshotData.write(to: ipcDir.appendingPathComponent("current_tasks.json"))

    let tools: [any Tool] = [
        ScheduleTaskToolWrapper(groupFolder: "test-group", chatJid: "test-chat", isMain: true),
        CancelTaskToolWrapper(groupFolder: "test-group")
    ]

    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: tools,
        memory: nil,
        inferenceProvider: nil,
        configurationName: "TestAgent"
    )

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_IPC_BASE_PATH", ipcDir.path) {
        let scheduled = try await agent.run("/schedule 08:00 Morning report")
        #expect(scheduled.output.contains("Task scheduled successfully"))

        let canceled = try await agent.run("/cancel task-123")
        #expect(canceled.output.contains("Canceled task"))
        #expect(canceled.output.contains("task-123"))
    }

    let taskFiles = try FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)
    #expect(taskFiles.count == 2)

    let payloads: [[String: Any]] = try taskFiles.map { fileURL in
        let data = try Data(contentsOf: fileURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    let taskTypes = Set(payloads.compactMap { $0["type"] as? String })
    #expect(taskTypes.contains("schedule_task"))
    #expect(taskTypes.contains("cancel_task"))
}

@Test
func testCancelTaskWrapperResolvesCaseInsensitiveTaskIDAndReturnsDefinitiveMessage() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ipcDir = tempDir.appendingPathComponent("ipc")
    let tasksDir = ipcDir.appendingPathComponent("tasks")
    try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let snapshot: [[String: Any]] = [[
        "id": "task-1770862295933-9FCA0C",
        "groupFolder": "test-group",
        "status": "paused",
        "prompt": "Test",
        "schedule_type": "cron",
        "schedule_value": "0 8 * * *",
        "next_run": "2026-02-16T00:00:00Z"
    ]]
    let snapshotData = try JSONSerialization.data(withJSONObject: snapshot)
    try snapshotData.write(to: ipcDir.appendingPathComponent("current_tasks.json"))

    let tool = CancelTaskToolWrapper(groupFolder: "test-group")
    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_IPC_BASE_PATH", ipcDir.path) {
        let result = try await tool.execute(arguments: ["task_id": .string("task-1770862295933-9fca0c")])
        let text = result.stringValue ?? ""
        #expect(text.contains("Canceled task"))
        #expect(text.contains("task-1770862295933-9FCA0C"))
        #expect(text.contains("Summary: Test"))
    }

    let taskFiles = try FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)
    #expect(taskFiles.count == 1)
    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: taskFiles[0])) as? [String: Any]
    #expect(payload?["type"] as? String == "cancel_task")
    #expect(payload?["task_id"] as? String == "task-1770862295933-9FCA0C")
}

@Test
func testCancelTaskWrapperReturnsNotFoundForUnknownTask() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ipcDir = tempDir.appendingPathComponent("ipc")
    let tasksDir = ipcDir.appendingPathComponent("tasks")
    try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let snapshotData = try JSONSerialization.data(withJSONObject: [[String: Any]]())
    try snapshotData.write(to: ipcDir.appendingPathComponent("current_tasks.json"))

    let tool = CancelTaskToolWrapper(groupFolder: "test-group")
    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_IPC_BASE_PATH", ipcDir.path) {
        let result = try await tool.execute(arguments: ["task_id": .string("task-missing")])
        #expect(result.stringValue == "I couldn’t find a task matching \"task-missing\". Try /tasks to see exact IDs.")
    }

    let taskFiles = try FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)
    #expect(taskFiles.isEmpty)
}

@Test
func testCancelTaskWrapperResolvesByTaskNameWhenUnique() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ipcDir = tempDir.appendingPathComponent("ipc")
    let tasksDir = ipcDir.appendingPathComponent("tasks")
    try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let snapshot: [[String: Any]] = [
        [
            "id": "task-1",
            "groupFolder": "test-group",
            "status": "paused",
            "prompt": "Morning report: Apple news summary"
        ],
        [
            "id": "task-2",
            "groupFolder": "test-group",
            "status": "paused",
            "prompt": "Weekly finance report"
        ]
    ]
    let snapshotData = try JSONSerialization.data(withJSONObject: snapshot)
    try snapshotData.write(to: ipcDir.appendingPathComponent("current_tasks.json"))

    let tool = CancelTaskToolWrapper(groupFolder: "test-group")
    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_IPC_BASE_PATH", ipcDir.path) {
        let result = try await tool.execute(arguments: ["task_id": .string("morning report")])
        let text = result.stringValue ?? ""
        #expect(text.contains("Canceled task"))
        #expect(text.contains("task-1"))
        #expect(text.contains("Morning report: Apple news summary"))
    }

    let taskFiles = try FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)
    #expect(taskFiles.count == 1)
    if let file = taskFiles.first {
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(payload?["task_id"] as? String == "task-1")
    }
}

@Test
func testCancelTaskWrapperReturnsAmbiguousWhenNameMatchesMultipleTasks() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ipcDir = tempDir.appendingPathComponent("ipc")
    let tasksDir = ipcDir.appendingPathComponent("tasks")
    try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let snapshot: [[String: Any]] = [
        [
            "id": "task-1",
            "groupFolder": "test-group",
            "status": "paused",
            "prompt": "Morning report: Apple news summary"
        ],
        [
            "id": "task-2",
            "groupFolder": "test-group",
            "status": "paused",
            "prompt": "Morning report: Infra status"
        ]
    ]
    let snapshotData = try JSONSerialization.data(withJSONObject: snapshot)
    try snapshotData.write(to: ipcDir.appendingPathComponent("current_tasks.json"))

    let tool = CancelTaskToolWrapper(groupFolder: "test-group")
    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_IPC_BASE_PATH", ipcDir.path) {
        let result = try await tool.execute(arguments: ["task_id": .string("morning report")])
        let text = result.stringValue ?? ""
        #expect(text.contains("I found multiple tasks matching \"morning report\"."))
        #expect(text.contains("task-1 - Morning report: Apple news summary [paused]"))
        #expect(text.contains("task-2 - Morning report: Infra status [paused]"))
        #expect(text.contains("Reply with the exact task ID"))
    }

    let taskFiles = try FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)
    #expect(taskFiles.isEmpty)
}

@Test
func testDefaultInstructionsIncludeFreshnessAndSourceGroundingPolicy() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let config = NanoClawConfig(apiKey: "test-api-key")
    let agent = await NanoClawAgent(config: config, groupFolder: tempDir.path)
    let instructions = agent.instructions

    #expect(instructions.contains("Never include internal tool transcript text in final replies"))
    #expect(instructions.contains("do not repeat the entire report again"))
    #expect(instructions.contains("For time-sensitive factual reports"))
    #expect(instructions.contains("Sources"))
    #expect(instructions.contains("As of"))
}

@Test
func testListTasksHighlightsPotentialDuplicates() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ipcDir = tempDir.appendingPathComponent("ipc")
    try FileManager.default.createDirectory(at: ipcDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let snapshot: [[String: Any]] = [
        [
            "id": "task-1",
            "groupFolder": "telegram-direct",
            "status": "active",
            "prompt": "Morning report: Apple product announcements",
            "schedule_type": "cron",
            "schedule_value": "0 8 * * *",
            "next_run": "2026-02-17T00:00:00Z",
            "scheduler_time_zone": "Asia/Singapore"
        ],
        [
            "id": "task-2",
            "groupFolder": "telegram-direct",
            "status": "paused",
            "prompt": "Morning report: Apple product announcements",
            "schedule_type": "cron",
            "schedule_value": "0 8 * * *",
            "next_run": "2026-02-17T00:00:00Z",
            "scheduler_time_zone": "Asia/Singapore"
        ]
    ]
    let snapshotData = try JSONSerialization.data(withJSONObject: snapshot)
    try snapshotData.write(to: ipcDir.appendingPathComponent("current_tasks.json"))

    let output = try await TestEnvironmentLock.shared.withEnv("NANOCLAW_IPC_BASE_PATH", ipcDir.path) {
        try await ListTasksToolWrapper(
            groupFolder: "telegram-direct",
            isMain: false,
            displayTimeZone: TimeZone(secondsFromGMT: 8 * 3600)!
        ).execute(arguments: [:])
    }

    let text = output.stringValue ?? ""
    #expect(text.contains("I found potential duplicate tasks"))
    #expect(text.contains("task-1"))
    #expect(text.contains("task-2"))
    #expect(text.contains("Scheduled tasks"))
    #expect(text.contains("Task ID: task-1"))
    #expect(text.contains("Status: Active"))
    #expect(text.contains("Schedule: Daily at 08:00 (Asia/Singapore)"))
    #expect(text.contains("Next run: 2026-02-17 08:00 GMT+08:00"))
    #expect(text.contains("(UTC 2026-02-17T00:00:00Z)"))
}
