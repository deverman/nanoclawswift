import Testing
import SwiftAgents
@testable import NanoClawAgent

actor SideEffectRecorder {
    private(set) var callCount = 0
    private(set) var lastArguments: [String: SendableValue]?

    func record(arguments: [String: SendableValue]) {
        callCount += 1
        lastArguments = arguments
    }
}

private struct RecordingSideEffectTool: Tool {
    let name: String
    let description: String = "Records side-effect calls"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "message", description: "message", type: .string)
    ]

    let recorder: SideEffectRecorder

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        await recorder.record(arguments: arguments)
        return .string("ok")
    }
}

private struct AllowApprovalHook: SideEffectApprovalHook {
    func evaluate(_ request: SideEffectApprovalRequest) async -> SideEffectApprovalDecision {
        _ = request
        return .approved
    }
}

private struct DenyApprovalHook: SideEffectApprovalHook {
    func evaluate(_ request: SideEffectApprovalRequest) async -> SideEffectApprovalDecision {
        _ = request
        return .denied(reason: "manual approval required")
    }
}

@Test
func testApprovalGatedToolBlocksDeniedSideEffects() async {
    let recorder = SideEffectRecorder()
    let wrapped = RecordingSideEffectTool(name: "send_message", recorder: recorder)
    let tool = ApprovalGatedTool(wrapped: wrapped, approvalHook: DenyApprovalHook())

    do {
        _ = try await tool.execute(arguments: ["message": .string("hi")])
        Issue.record("Expected approval gate to deny call")
    } catch let error as AgentError {
        guard case .toolExecutionFailed(let toolName, let reason) = error else {
            Issue.record("Unexpected agent error: \(error)")
            return
        }
        #expect(toolName == "send_message")
        #expect(reason.contains("manual approval required"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    let callCount = await recorder.callCount
    #expect(callCount == 0)
}

@Test
func testApprovalGatedToolAddsIdempotencyMetadata() async throws {
    let recorder = SideEffectRecorder()
    let wrapped = RecordingSideEffectTool(name: "send_message", recorder: recorder)
    let tool = ApprovalGatedTool(wrapped: wrapped, approvalHook: AllowApprovalHook())

    _ = try await tool.execute(arguments: ["message": .string("hi")])

    let callCount = await recorder.callCount
    #expect(callCount == 1)
    let lastArguments = await recorder.lastArguments
    #expect(lastArguments?["idempotency_key"]?.stringValue?.isEmpty == false)
}

@Test
func testSideEffectIdempotencyKeyIsStableForEquivalentArguments() {
    let baseline = SideEffectIdempotency.makeKey(
        toolName: "send_message",
        arguments: [
            "message": .string("hello")
        ]
    )

    let withToken = SideEffectIdempotency.makeKey(
        toolName: "send_message",
        arguments: [
            "approval_token": .string("abc"),
            "message": .string("hello")
        ]
    )

    #expect(baseline == withToken)
}

@Test
func testApprovalGatedToolExposesApprovalAndIdempotencyParameters() {
    let recorder = SideEffectRecorder()
    let wrapped = RecordingSideEffectTool(name: "send_message", recorder: recorder)
    let tool = ApprovalGatedTool(wrapped: wrapped, approvalHook: AllowApprovalHook())

    let paramNames = Set(tool.parameters.map(\.name))
    #expect(paramNames.contains("approval_token"))
    #expect(paramNames.contains("idempotency_key"))
}

@Test
func testWriteMemoryIsTreatedAsSideEffectTool() {
    #expect(NanoClawAgent.sideEffectToolNames.contains("write_memory"))
}
