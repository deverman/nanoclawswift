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
        let index = step
        step += 1
        if index < outputs.count {
            return outputs[index]
        }
        return InferenceResponse(content: "final", finishReason: .completed)
    }
}

@Test
func testToolCallLoopExecutesToolAndFinalResponse() async throws {
    let recorder = ToolCallRecorder()
    let tool = EchoTool(recorder: recorder)
    let provider = SequencedInferenceProvider(outputs: [
        InferenceResponse(
            content: nil,
            toolCalls: [
                InferenceResponse.ParsedToolCall(
                    id: UUID().uuidString,
                    name: "echo",
                    arguments: ["text": .string("hello")]
                )
            ],
            finishReason: .toolCall,
            usage: nil
        ),
        InferenceResponse(content: "final", finishReason: .completed)
    ])

    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [tool],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("Hello")
    #expect(result.output == "final")

    let called = await recorder.called
    #expect(called == true)
}

@Test
func testPseudoToolSyntaxIsRejectedAndNotExecuted() async throws {
    let recorder = ToolCallRecorder()
    let tool = EchoTool(recorder: recorder)
    let provider = SequencedInferenceProvider(outputs: [
        InferenceResponse(
            content: """
            ```tool
            schedule_task:0>{\"schedule_type\":\"recurring\",\"time\":\"08:00\"}
            ```
            """,
            toolCalls: [],
            finishReason: .completed,
            usage: nil
        )
    ])

    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: [tool],
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    let result = try await agent.run("Please schedule this")
    #expect(result.output.contains("could not execute that action"))

    let called = await recorder.called
    #expect(called == false)
}

@Test
func testStructuredScheduleAndCancelPersistIPCRequests() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ipcDir = tempDir.appendingPathComponent("ipc")
    let tasksDir = ipcDir.appendingPathComponent("tasks")
    try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let provider = SequencedInferenceProvider(outputs: [
        InferenceResponse(
            content: nil,
            toolCalls: [
                InferenceResponse.ParsedToolCall(
                    id: UUID().uuidString,
                    name: "schedule_task",
                    arguments: [
                        "description": .string("Morning report"),
                        "schedule_type": .string("recurring"),
                        "time": .string("08:00")
                    ]
                )
            ],
            finishReason: .toolCall,
            usage: nil
        ),
        InferenceResponse(content: "scheduled", finishReason: .completed),
        InferenceResponse(
            content: nil,
            toolCalls: [
                InferenceResponse.ParsedToolCall(
                    id: UUID().uuidString,
                    name: "cancel_task",
                    arguments: [
                        "task_id": .string("task-123")
                    ]
                )
            ],
            finishReason: .toolCall,
            usage: nil
        ),
        InferenceResponse(content: "canceled", finishReason: .completed)
    ])

    let tools: [any Tool] = [
        ScheduleTaskToolWrapper(groupFolder: "test-group", chatJid: "test-chat", isMain: true),
        CancelTaskToolWrapper(groupFolder: "test-group")
    ]

    let agent = await NanoClawAgent(
        groupFolder: "/tmp/test",
        instructions: "Test",
        tools: tools,
        memory: nil,
        inferenceProvider: provider,
        configurationName: "TestAgent"
    )

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_IPC_BASE_PATH", ipcDir.path) {
        let scheduled = try await agent.run("Please schedule this")
        #expect(scheduled.output == "scheduled")

        let canceled = try await agent.run("Please cancel task-123")
        #expect(canceled.output == "canceled")
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
