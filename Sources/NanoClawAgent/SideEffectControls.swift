import Foundation
import SwiftAgents

public struct SideEffectApprovalRequest: Sendable {
    public let toolName: String
    public let arguments: [String: SendableValue]
    public let idempotencyKey: String

    public init(toolName: String, arguments: [String: SendableValue], idempotencyKey: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.idempotencyKey = idempotencyKey
    }
}

public enum SideEffectApprovalDecision: Sendable, Equatable {
    case approved
    case denied(reason: String)
}

public protocol SideEffectApprovalHook: Sendable {
    func evaluate(_ request: SideEffectApprovalRequest) async -> SideEffectApprovalDecision
}

public struct AllowAllSideEffectApprovalHook: SideEffectApprovalHook {
    public init() {}

    public func evaluate(_ request: SideEffectApprovalRequest) async -> SideEffectApprovalDecision {
        _ = request
        return .approved
    }
}

public struct EnvironmentSideEffectApprovalHook: SideEffectApprovalHook {
    public init() {}

    public func evaluate(_ request: SideEffectApprovalRequest) async -> SideEffectApprovalDecision {
        let environment = ProcessInfo.processInfo.environment
        let mode = (environment["NANOCLAW_SIDE_EFFECT_APPROVAL_MODE"] ?? "allow").lowercased()
        guard mode == "required" else {
            return .approved
        }

        let providedToken = request.arguments["approval_token"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedToken = environment["NANOCLAW_SIDE_EFFECT_APPROVAL_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let expectedToken, !expectedToken.isEmpty {
            if providedToken == expectedToken {
                return .approved
            }
            return .denied(reason: "approval token mismatch")
        }

        if let providedToken, !providedToken.isEmpty {
            return .approved
        }
        return .denied(reason: "approval token required")
    }
}

struct ApprovalGatedTool: Tool {
    let wrapped: any Tool
    let approvalHook: any SideEffectApprovalHook

    var name: String { wrapped.name }

    var description: String {
        "\(wrapped.description) (side-effect controlled: approval + idempotency metadata)"
    }

    var parameters: [ToolParameter] {
        var merged = wrapped.parameters
        if !merged.contains(where: { $0.name == "approval_token" }) {
            merged.append(
                ToolParameter(
                    name: "approval_token",
                    description: "Optional approval token required when side-effect approval mode is enforced",
                    type: .string,
                    isRequired: false
                )
            )
        }
        if !merged.contains(where: { $0.name == "idempotency_key" }) {
            merged.append(
                ToolParameter(
                    name: "idempotency_key",
                    description: "Optional idempotency key for safe retries (auto-generated when omitted)",
                    type: .string,
                    isRequired: false
                )
            )
        }
        return merged
    }

    var inputGuardrails: [any ToolInputGuardrail] {
        wrapped.inputGuardrails
    }

    var outputGuardrails: [any ToolOutputGuardrail] {
        wrapped.outputGuardrails
    }

    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        var controlledArguments = arguments
        let idempotencyKey: String
        if let provided = controlledArguments["idempotency_key"]?.stringValue,
           !provided.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            idempotencyKey = provided
        } else {
            idempotencyKey = SideEffectIdempotency.makeKey(toolName: wrapped.name, arguments: controlledArguments)
            controlledArguments["idempotency_key"] = .string(idempotencyKey)
        }

        let request = SideEffectApprovalRequest(
            toolName: wrapped.name,
            arguments: controlledArguments,
            idempotencyKey: idempotencyKey
        )

        switch await approvalHook.evaluate(request) {
        case .approved:
            return try await wrapped.execute(arguments: controlledArguments)
        case .denied(let reason):
            throw AgentError.toolExecutionFailed(
                toolName: wrapped.name,
                underlyingError: "side-effect approval denied: \(reason)"
            )
        }
    }
}

enum SideEffectIdempotency {
    static func makeKey(toolName: String, arguments: [String: SendableValue]) -> String {
        let filtered = arguments
            .filter { key, _ in
                key != "approval_token" && key != "idempotency_key"
            }
            .sorted(by: { $0.key < $1.key })

        let canonicalBody = filtered
            .map { key, value in "\(escape(key))=\(canonical(value))" }
            .joined(separator: "&")

        let digest = fnv1a64("\(toolName)|\(canonicalBody)")
        return String(format: "nc-%016llx", digest)
    }

    private static func canonical(_ value: SendableValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let boolValue):
            return boolValue ? "true" : "false"
        case .int(let intValue):
            return "i:\(intValue)"
        case .double(let doubleValue):
            return "d:\(doubleValue)"
        case .string(let stringValue):
            return "s:\(escape(stringValue))"
        case .array(let values):
            let rendered = values.map(canonical).joined(separator: ",")
            return "[\(rendered)]"
        case .dictionary(let dictionary):
            let rendered = dictionary
                .sorted(by: { $0.key < $1.key })
                .map { key, nested in "\(escape(key)):\(canonical(nested))" }
                .joined(separator: ",")
            return "{\(rendered)}"
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "=", with: "\\=")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ":", with: "\\:")
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        let prime: UInt64 = 1099511628211
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

func resolvedIdempotencyKey(toolName: String, arguments: [String: SendableValue]) -> String {
    if let provided = arguments["idempotency_key"]?.stringValue,
       !provided.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return provided
    }
    return SideEffectIdempotency.makeKey(toolName: toolName, arguments: arguments)
}

extension NanoClawAgent {
    nonisolated static var sideEffectToolNames: Set<String> {
        [
            "send_message",
            "schedule_task",
            "pause_task",
            "resume_task",
            "cancel_task",
            "write_memory"
        ]
    }

    nonisolated static func wrapSideEffectTools(
        _ tools: [any Tool],
        approvalHook: any SideEffectApprovalHook = EnvironmentSideEffectApprovalHook()
    ) -> [any Tool] {
        tools.map { tool in
            if sideEffectToolNames.contains(tool.name) {
                return ApprovalGatedTool(wrapped: tool, approvalHook: approvalHook)
            }
            return tool
        }
    }
}
