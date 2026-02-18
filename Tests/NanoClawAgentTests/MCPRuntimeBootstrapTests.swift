import Foundation
import Testing

@testable import NanoClawAgent

@Test
func testMCPRuntimeBootstrapReturnsEmptyWhenConfigMissing() async {
    let bootstrap = await MCPRuntimeBootstrapLoader.load(
        environment: ["NANOCLAW_MCP_CONFIG_PATH": "/tmp/does-not-exist-\(UUID().uuidString).json"]
    )
    #expect(bootstrap.tools.isEmpty)
    #expect(bootstrap.executor == nil)
    #expect(bootstrap.status.hasConfig == false)
    #expect(bootstrap.status.loadedToolCount == 0)
}

@Test
func testMCPRuntimeBootstrapSurfacesSkippedDiagnostics() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configPath = tempDir.appendingPathComponent(".mcp.json")
    try """
    {
      "mcpServers": {
        "host-only": {
          "runtime": "host",
          "command": "/bin/echo"
        }
      }
    }
    """.write(to: configPath, atomically: true, encoding: .utf8)

    let bootstrap = await MCPRuntimeBootstrapLoader.load(
        environment: ["NANOCLAW_MCP_CONFIG_PATH": configPath.path]
    )

    #expect(bootstrap.tools.isEmpty)
    #expect(bootstrap.executor == nil)
    #expect(bootstrap.diagnostics.contains(where: { $0.contains("host-only:hostBridgeUnavailable") }))
    #expect(bootstrap.status.hasConfig == true)
    #expect(bootstrap.status.configuredServerCount == 1)
    #expect(bootstrap.status.loadedServerIDs.isEmpty)
    #expect(bootstrap.status.skippedServers.count == 1)
}

@Test
func testMCPRuntimeBootstrapSkipsHostServersWhenBridgeURLMissing() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configPath = tempDir.appendingPathComponent(".mcp.json")
    try """
    {
      "mcpServers": {
        "focusrelay": {
          "runtime": "host",
          "command": "/opt/homebrew/bin/focusrelay-mcp",
          "args": ["serve"]
        }
      }
    }
    """.write(to: configPath, atomically: true, encoding: .utf8)

    let bootstrap = await MCPRuntimeBootstrapLoader.load(
        environment: ["NANOCLAW_MCP_CONFIG_PATH": configPath.path]
    )

    #expect(bootstrap.tools.isEmpty)
    #expect(bootstrap.status.hasConfig == true)
    #expect(bootstrap.status.configuredServerCount == 1)
    #expect(bootstrap.status.loadedServerIDs.isEmpty)
    #expect(bootstrap.status.skippedServers.contains(where: {
        $0.id == "focusrelay" && $0.reason == .hostBridgeUnavailable
    }))
}
