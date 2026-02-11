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

struct MockInferenceProvider: InferenceProvider {
    func generate(prompt: String, options: InferenceOptions) async throws -> String {
        return "final"
    }

    func stream(prompt: String, options: InferenceOptions) -> AsyncThrowingStream<String, Error> {
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
        let toolCall = InferenceResponse.ParsedToolCall(
            id: UUID().uuidString,
            name: "echo",
            arguments: ["text": .string("hello")]
        )

        return InferenceResponse(
            content: nil,
            toolCalls: [toolCall],
            finishReason: .toolCall,
            usage: nil
        )
    }
}

@Test
func testToolCallLoopExecutesToolAndFinalResponse() async throws {
    let recorder = ToolCallRecorder()
    let tool = EchoTool(recorder: recorder)
    let provider = MockInferenceProvider()

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
