import Foundation
import SwiftAgents
import Testing
@testable import NanoClawAgent

@Test
func testToolBackendSelectionPrecedence() throws {
    let policy = HostFallbackPolicy(allowlistedCommands: ["brew-tool"], approvalRequired: true)

    let containerCLI = try ToolBackendSelector.select(
        toolName: "search",
        availability: ToolBackendAvailability(
            containerCLICommand: "container-search",
            containerMCPTool: "mcp.search",
            hostFallbackCommand: "brew-tool"
        ),
        hostPolicy: policy,
        hasExplicitHostApproval: false
    )
    #expect(containerCLI.kind == .containerCLI)

    let containerMCP = try ToolBackendSelector.select(
        toolName: "search",
        availability: ToolBackendAvailability(
            containerCLICommand: nil,
            containerMCPTool: "mcp.search",
            hostFallbackCommand: "brew-tool"
        ),
        hostPolicy: policy,
        hasExplicitHostApproval: false
    )
    #expect(containerMCP.kind == .containerMCP)

    let hostFallback = try ToolBackendSelector.select(
        toolName: "search",
        availability: ToolBackendAvailability(
            containerCLICommand: nil,
            containerMCPTool: nil,
            hostFallbackCommand: "brew-tool"
        ),
        hostPolicy: policy,
        hasExplicitHostApproval: true
    )
    #expect(hostFallback.kind == .hostFallback)
}

@Test
func testToolBackendSelectionEnforcesAllowlistAndApproval() {
    let policy = HostFallbackPolicy(allowlistedCommands: ["safe-tool"], approvalRequired: true)
    let availability = ToolBackendAvailability(
        containerCLICommand: nil,
        containerMCPTool: nil,
        hostFallbackCommand: "danger-tool"
    )

    do {
        _ = try ToolBackendSelector.select(
            toolName: "search",
            availability: availability,
            hostPolicy: policy,
            hasExplicitHostApproval: true
        )
        Issue.record("Expected allowlist enforcement to reject non-allowlisted host fallback command")
    } catch let error as ToolBackendSelectionError {
        #expect(error == .hostCommandNotAllowlisted(command: "danger-tool"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    do {
        _ = try ToolBackendSelector.select(
            toolName: "search",
            availability: ToolBackendAvailability(
                containerCLICommand: nil,
                containerMCPTool: nil,
                hostFallbackCommand: "safe-tool"
            ),
            hostPolicy: policy,
            hasExplicitHostApproval: false
        )
        Issue.record("Expected explicit host approval requirement to be enforced")
    } catch let error as ToolBackendSelectionError {
        #expect(error == .hostApprovalRequired(command: "safe-tool"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test
func testToolBackendSelectionAllowsBasenameAllowlistForAbsoluteHostCommand() throws {
    let policy = HostFallbackPolicy(allowlistedCommands: ["brew-tool"], approvalRequired: true)

    let selection = try ToolBackendSelector.select(
        toolName: "search",
        availability: ToolBackendAvailability(
            containerCLICommand: nil,
            containerMCPTool: nil,
            hostFallbackCommand: "/opt/homebrew/bin/brew-tool"
        ),
        hostPolicy: policy,
        hasExplicitHostApproval: true
    )

    #expect(selection == ToolBackendSelection(kind: .hostFallback, identifier: "/opt/homebrew/bin/brew-tool"))
}

@Test
func testToolBackendSelectionFailsWhenNoBackendAvailable() {
    let policy = HostFallbackPolicy(allowlistedCommands: [], approvalRequired: true)

    do {
        _ = try ToolBackendSelector.select(
            toolName: "search",
            availability: ToolBackendAvailability(
                containerCLICommand: nil,
                containerMCPTool: nil,
                hostFallbackCommand: nil
            ),
            hostPolicy: policy,
            hasExplicitHostApproval: false
        )
        Issue.record("Expected no backend available error")
    } catch let error as ToolBackendSelectionError {
        #expect(error == .noBackendAvailable(toolName: "search"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test
func testContainerCLIAdapterValidatesTypesAndBuildsInvocation() throws {
    let adapter = ContainerCLIAdapter(
        command: "tool-runner",
        argumentSpecs: [
            CLIArgumentSpec(name: "query", flag: "--query", type: .string, isRequired: true),
            CLIArgumentSpec(name: "limit", flag: "--limit", type: .int, isRequired: false),
            CLIArgumentSpec(name: "strict", flag: "--strict", type: .bool, isRequired: false)
        ]
    )

    let invocation = try adapter.buildInvocation(arguments: [
        "query": .string("swift"),
        "limit": .int(5),
        "strict": .bool(true)
    ])

    #expect(invocation.command == "tool-runner")
    #expect(invocation.arguments == ["--query", "swift", "--limit", "5", "--strict", "true"])
}

@Test
func testContainerCLIAdapterRejectsMissingOrInvalidArguments() {
    let adapter = ContainerCLIAdapter(
        command: "tool-runner",
        argumentSpecs: [
            CLIArgumentSpec(name: "query", flag: "--query", type: .string, isRequired: true),
            CLIArgumentSpec(name: "limit", flag: "--limit", type: .int, isRequired: false)
        ]
    )

    do {
        _ = try adapter.buildInvocation(arguments: [:])
        Issue.record("Expected missing required argument error")
    } catch let error as CLIArgumentValidationError {
        #expect(error == .missingRequiredArgument(name: "query"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    do {
        _ = try adapter.buildInvocation(arguments: [
            "query": .string("swift"),
            "limit": .string("oops")
        ])
        Issue.record("Expected invalid type error")
    } catch let error as CLIArgumentValidationError {
        #expect(error == .invalidType(name: "limit", expected: .int))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}
