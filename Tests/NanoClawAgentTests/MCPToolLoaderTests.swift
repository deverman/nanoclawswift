import Foundation
import MCP
import SwiftAgents
import Testing
@testable import NanoClawAgent

actor MCPTestExecutor: MCPToolExecutor {
    private(set) var lastServerID: String?
    private(set) var lastToolName: String?
    private(set) var lastArguments: [String: Value] = [:]
    private let response: MCPToolExecutionResult

    init(response: MCPToolExecutionResult) {
        self.response = response
    }

    func callTool(
        serverID: String,
        toolName: String,
        arguments: [String: Value]
    ) async throws -> MCPToolExecutionResult {
        self.lastServerID = serverID
        self.lastToolName = toolName
        self.lastArguments = arguments
        return response
    }
}

@Test
func testMCPToolLoaderParsesContainerServerConfig() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configURL = tempDir.appendingPathComponent(".mcp.json")
    let json = """
    {
      "mcpServers": {
        "filesystem": {
          "runtime": "container",
          "transport": "stdio",
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "${WORKSPACE}"],
          "cwd": "tools",
          "env": {
            "ROOT_PATH": "${WORKSPACE}"
          }
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: configURL)

    let report = try MCPToolLoader.loadContainerServers(
        from: configURL,
        containerWorkspace: URL(fileURLWithPath: "/workspace/group"),
        environment: ["WORKSPACE": "/workspace/group"]
    )

    #expect(report.servers.count == 1)
    #expect(report.skipped.isEmpty)

    let server = try #require(report.servers.first)
    #expect(server.id == "filesystem")
    #expect(server.command == "npx")
    #expect(server.arguments == ["-y", "@modelcontextprotocol/server-filesystem", "/workspace/group"])
    #expect(server.workingDirectory == "/workspace/group/tools")
    #expect(server.environment["ROOT_PATH"] == "/workspace/group")
}

@Test
func testMCPToolLoaderSkipsNonContainerOrInvalidServers() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configURL = tempDir.appendingPathComponent(".mcp.json")
    let json = """
    {
      "mcpServers": {
        "valid": {
          "command": "uvx",
          "args": ["mcp-server-time"],
          "runtime": "container"
        },
        "disabled": {
          "command": "uvx",
          "args": ["mcp-server-git"],
          "disabled": true
        },
        "hostOnly": {
          "command": "/opt/homebrew/bin/my-mcp",
          "runtime": "host"
        },
        "noCommand": {
          "args": ["missing-command"]
        },
        "httpTransport": {
          "command": "python3",
          "transport": "http"
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: configURL)

    let report = try MCPToolLoader.loadContainerServers(from: configURL)

    #expect(report.servers.map(\.id) == ["valid"])
    #expect(report.skipped.count == 4)
    #expect(report.skipped.contains(where: { $0.id == "disabled" && $0.reason == .disabled }))
    #expect(report.skipped.contains(where: { $0.id == "hostOnly" && $0.reason == .hostRuntimeUnsupported }))
    #expect(report.skipped.contains(where: { $0.id == "noCommand" && $0.reason == .missingCommand }))
    #expect(report.skipped.contains(where: { $0.id == "httpTransport" && $0.reason == .unsupportedTransport }))
}

@Test
func testMCPToolLoaderParsesHostAndContainerServers() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configURL = tempDir.appendingPathComponent(".mcp.json")
    let json = """
    {
      "mcpServers": {
        "filesystem": {
          "runtime": "container",
          "transport": "stdio",
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "${WORKSPACE}"],
          "cwd": "tools"
        },
        "focusrelay": {
          "runtime": "host",
          "transport": "stdio",
          "command": "/opt/homebrew/bin/focusrelay-mcp",
          "args": ["serve"],
          "env": {
            "FOCUSRELAY_MODE": "bridge"
          }
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: configURL)

    let report = try MCPToolLoader.loadServers(
        from: configURL,
        containerWorkspace: URL(fileURLWithPath: "/workspace/group"),
        environment: ["WORKSPACE": "/workspace/group"]
    )

    #expect(report.containerServers.count == 1)
    #expect(report.hostServers.count == 1)
    #expect(report.skipped.isEmpty)

    let host = try #require(report.hostServers.first)
    #expect(host.id == "focusrelay")
    #expect(host.command == "/opt/homebrew/bin/focusrelay-mcp")
    #expect(host.arguments == ["serve"])
    #expect(host.environment["FOCUSRELAY_MODE"] == "bridge")
}

@Test
func testMCPToolRegistrationPipelineBridgesSchemaAndExecution() async throws {
    let schema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Path to inspect")
            ]),
            "recursive": .object([
                "type": .string("boolean"),
                "default": .bool(false)
            ]),
            "mode": .object([
                "type": .string("string"),
                "enum": .array([.string("fast"), .string("safe")])
            ])
        ]),
        "required": .array([.string("path")])
    ])

    let registration = MCPToolRegistration(
        serverID: "filesystem",
        tool: MCPToolDescriptor(
            name: "scan",
            description: "Scan a path",
            inputSchema: schema
        )
    )

    let executor = MCPTestExecutor(
        response: MCPToolExecutionResult(output: "scan-ok", isError: false)
    )
    let tools = MCPToolRegistrationPipeline.buildTools(
        registrations: [registration],
        executor: executor
    )

    #expect(tools.count == 1)
    let bridgedTool = try #require(tools.first)
    #expect(bridgedTool.name == "mcp_filesystem_scan")
    #expect(bridgedTool.description.contains("filesystem"))

    let pathParam = try #require(bridgedTool.parameters.first(where: { $0.name == "path" }))
    #expect(pathParam.isRequired)
    #expect(pathParam.type == .string)

    let recursiveParam = try #require(bridgedTool.parameters.first(where: { $0.name == "recursive" }))
    #expect(!recursiveParam.isRequired)
    #expect(recursiveParam.type == .bool)

    let modeParam = try #require(bridgedTool.parameters.first(where: { $0.name == "mode" }))
    #expect(modeParam.type == .oneOf(["fast", "safe"]))

    let output = try await bridgedTool.execute(arguments: [
        "path": .string("/workspace/group"),
        "recursive": .bool(true)
    ])

    #expect(output.stringValue == "scan-ok")
    #expect(await executor.lastServerID == "filesystem")
    #expect(await executor.lastToolName == "scan")
    #expect(await executor.lastArguments["path"] == .string("/workspace/group"))
    #expect(await executor.lastArguments["recursive"] == .bool(true))
}

@Test
func testMCPToolRegistrationPipelineThrowsAgentErrorForMCPErrorResult() async {
    let registration = MCPToolRegistration(
        serverID: "filesystem",
        tool: MCPToolDescriptor(
            name: "scan",
            description: nil,
            inputSchema: .object([:])
        )
    )

    let executor = MCPTestExecutor(
        response: MCPToolExecutionResult(output: "permission denied", isError: true)
    )
    let tools = MCPToolRegistrationPipeline.buildTools(
        registrations: [registration],
        executor: executor
    )
    #expect(tools.count == 1)
    guard tools.count == 1 else {
        Issue.record("Expected a bridged MCP tool")
        return
    }
    let tool = tools[0]

    do {
        _ = try await tool.execute(arguments: [:])
        Issue.record("Expected MCP error response to throw tool execution error")
    } catch let error as AgentError {
        guard case .toolExecutionFailed(let toolName, let reason) = error else {
            Issue.record("Unexpected AgentError case: \(error)")
            return
        }
        #expect(toolName == "mcp_filesystem_scan")
        #expect(reason.contains("permission denied"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}
