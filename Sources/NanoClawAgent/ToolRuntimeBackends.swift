import Foundation
import SwiftAgents

public enum ToolBackendKind: String, Sendable, Equatable {
    case containerCLI = "container_cli"
    case containerMCP = "container_mcp"
    case hostFallback = "host_fallback"
}

public struct ToolBackendSelection: Sendable, Equatable {
    public let kind: ToolBackendKind
    public let identifier: String

    public init(kind: ToolBackendKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

public struct ToolBackendAvailability: Sendable, Equatable {
    public let containerCLICommand: String?
    public let containerMCPTool: String?
    public let hostFallbackCommand: String?

    public init(
        containerCLICommand: String?,
        containerMCPTool: String?,
        hostFallbackCommand: String?
    ) {
        self.containerCLICommand = containerCLICommand
        self.containerMCPTool = containerMCPTool
        self.hostFallbackCommand = hostFallbackCommand
    }
}

public struct HostFallbackPolicy: Sendable, Equatable {
    public let allowlistedCommands: Set<String>
    public let approvalRequired: Bool

    public init(allowlistedCommands: Set<String>, approvalRequired: Bool) {
        self.allowlistedCommands = allowlistedCommands
        self.approvalRequired = approvalRequired
    }
}

public enum ToolBackendSelectionError: Error, Sendable, Equatable {
    case noBackendAvailable(toolName: String)
    case hostCommandNotAllowlisted(command: String)
    case hostApprovalRequired(command: String)
}

public enum ToolBackendSelector {
    public static func select(
        toolName: String,
        availability: ToolBackendAvailability,
        hostPolicy: HostFallbackPolicy,
        hasExplicitHostApproval: Bool
    ) throws -> ToolBackendSelection {
        if let containerCommand = availability.containerCLICommand?.trimmed, !containerCommand.isEmpty {
            return ToolBackendSelection(kind: .containerCLI, identifier: containerCommand)
        }

        if let mcpTool = availability.containerMCPTool?.trimmed, !mcpTool.isEmpty {
            return ToolBackendSelection(kind: .containerMCP, identifier: mcpTool)
        }

        if let hostCommand = availability.hostFallbackCommand?.trimmed, !hostCommand.isEmpty {
            guard isAllowlisted(hostCommand, allowlist: hostPolicy.allowlistedCommands) else {
                throw ToolBackendSelectionError.hostCommandNotAllowlisted(command: hostCommand)
            }
            if hostPolicy.approvalRequired && !hasExplicitHostApproval {
                throw ToolBackendSelectionError.hostApprovalRequired(command: hostCommand)
            }
            return ToolBackendSelection(kind: .hostFallback, identifier: hostCommand)
        }

        throw ToolBackendSelectionError.noBackendAvailable(toolName: toolName)
    }

    private static func isAllowlisted(_ command: String, allowlist: Set<String>) -> Bool {
        if allowlist.contains(command) {
            return true
        }
        let basename = URL(fileURLWithPath: command).lastPathComponent
        return allowlist.contains(basename)
    }
}

public enum CLIArgumentType: String, Sendable, Equatable {
    case string
    case int
    case bool
}

public struct CLIArgumentSpec: Sendable, Equatable {
    public let name: String
    public let flag: String
    public let type: CLIArgumentType
    public let isRequired: Bool

    public init(name: String, flag: String, type: CLIArgumentType, isRequired: Bool) {
        self.name = name
        self.flag = flag
        self.type = type
        self.isRequired = isRequired
    }
}

public struct CLIInvocation: Sendable, Equatable {
    public let command: String
    public let arguments: [String]

    public init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }
}

public enum CLIArgumentValidationError: Error, Sendable, Equatable {
    case missingRequiredArgument(name: String)
    case invalidType(name: String, expected: CLIArgumentType)
}

public struct ContainerCLIAdapter: Sendable {
    public let command: String
    public let argumentSpecs: [CLIArgumentSpec]

    public init(command: String, argumentSpecs: [CLIArgumentSpec]) {
        self.command = command
        self.argumentSpecs = argumentSpecs
    }

    public func buildInvocation(arguments: [String: SendableValue]) throws -> CLIInvocation {
        var renderedArguments: [String] = []

        for spec in argumentSpecs {
            guard let value = arguments[spec.name] else {
                if spec.isRequired {
                    throw CLIArgumentValidationError.missingRequiredArgument(name: spec.name)
                }
                continue
            }

            let renderedValue: String
            switch spec.type {
            case .string:
                guard let typed = value.stringValue else {
                    throw CLIArgumentValidationError.invalidType(name: spec.name, expected: .string)
                }
                renderedValue = typed
            case .int:
                guard let typed = value.intValue else {
                    throw CLIArgumentValidationError.invalidType(name: spec.name, expected: .int)
                }
                renderedValue = String(typed)
            case .bool:
                guard let typed = value.boolValue else {
                    throw CLIArgumentValidationError.invalidType(name: spec.name, expected: .bool)
                }
                renderedValue = typed ? "true" : "false"
            }

            renderedArguments.append(spec.flag)
            renderedArguments.append(renderedValue)
        }

        return CLIInvocation(command: command, arguments: renderedArguments)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
