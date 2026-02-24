import Testing
import Foundation
import SwiftAgents
@testable import NanoClawAgent

private struct OverlaySnapshot: Codable {
    let version: Int
    let allow: [String]
    let deny: [String]
}

private actor SubAgentTestProvider: InferenceProvider {
    private(set) var prompts: [String] = []
    private(set) var options: [InferenceOptions] = []
    private let response: String

    init(response: String) {
        self.response = response
    }

    func generate(prompt: String, options: InferenceOptions) async throws -> String {
        prompts.append(prompt)
        self.options.append(options)
        return response
    }

    nonisolated func stream(prompt: String, options: InferenceOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func generateWithToolCalls(
        prompt: String,
        tools: [ToolDefinition],
        options: InferenceOptions
    ) async throws -> InferenceResponse {
        _ = prompt
        _ = tools
        _ = options
        return InferenceResponse(content: response, finishReason: .completed)
    }
}

@Test
func testReadWriteTools() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", tempDir.path) {
        let write = WriteTool()
        _ = try await write.execute(arguments: [
            "file_path": .string("notes.txt"),
            "content": .string("Hello"),
            "append": .bool(false)
        ])

        let read = ReadTool()
        let content = try await read.execute(arguments: [
            "file_path": .string("notes.txt")
        ])
        #expect(content.stringValue == "Hello")
    }
}

@Test
func testEditTool() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", tempDir.path) {
        let write = WriteTool()
        _ = try await write.execute(arguments: [
            "file_path": .string("edit.txt"),
            "content": .string("Hello World"),
            "append": .bool(false)
        ])

        let edit = EditTool()
        _ = try await edit.execute(arguments: [
            "file_path": .string("edit.txt"),
            "find": .string("World"),
            "replace": .string("Swift"),
            "use_regex": .bool(false)
        ])

        let read = ReadTool()
        let content = try await read.execute(arguments: [
            "file_path": .string("edit.txt")
        ])
        #expect(content.stringValue == "Hello Swift")
    }
}

@Test
func testGlobAndGrep() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", tempDir.path) {
        let writeA = WriteTool()
        let writeB = WriteTool()
        _ = try await writeA.execute(arguments: [
            "file_path": .string("a.txt"),
            "content": .string("alpha"),
            "append": .bool(false)
        ])
        _ = try await writeB.execute(arguments: [
            "file_path": .string("b.txt"),
            "content": .string("beta"),
            "append": .bool(false)
        ])

        let glob = GlobTool()
        let results = try await glob.execute(arguments: ["pattern": .string("*.txt")])
        let files = Set((results.stringValue ?? "").split(separator: "\n").map(String.init))
        #expect(files.contains("a.txt"))
        #expect(files.contains("b.txt"))

        let grep = GrepTool()
        let matches = try await grep.execute(arguments: [
            "pattern": .string("alpha"),
            "file_pattern": .string("*.txt"),
            "use_regex": .bool(false)
        ])
        #expect((matches.stringValue ?? "").contains("a.txt:1:alpha"))
    }
}

@Test
func testGlobRejectsEmptyPattern() async throws {
    let glob = GlobTool()
    var didThrow = false
    do {
        _ = try await glob.execute(arguments: ["pattern": .string("   ")])
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

@Test
func testWebPolicyOverlayTools() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await TestEnvironmentLock.shared.withEnvs([
        "NANOCLAW_BASE_PATH": tempDir.path,
        "NANOCLAW_GROUP_FOLDER": "test-group"
    ]) {
        let addTool = WebPolicyAddDomainTool()
        _ = try await addTool.execute(arguments: [
            "domain": .string("Example.com"),
            "note": .string("test")
        ])

        let overlayPath = tempDir.appendingPathComponent(".nanoclaw/web-policy.overlay.json")
        #expect(FileManager.default.fileExists(atPath: overlayPath.path))

        let initialData = try Data(contentsOf: overlayPath)
        let initialSnapshot = try JSONDecoder().decode(OverlaySnapshot.self, from: initialData)
        #expect(initialSnapshot.allow.contains("example.com"))

        let removeTool = WebPolicyRemoveDomainTool()
        _ = try await removeTool.execute(arguments: [
            "domain": .string("example.com")
        ])

        let updatedData = try Data(contentsOf: overlayPath)
        let updatedSnapshot = try JSONDecoder().decode(OverlaySnapshot.self, from: updatedData)
        #expect(!updatedSnapshot.allow.contains("example.com"))
    }
}

@Test
func testWebFetchToolValidatesBrokerConfiguration() async throws {
    try await TestEnvironmentLock.shared.withEnvs([
        "NANOCLAW_WEB_BROKER_URL": "not-a-valid-url",
        "NANOCLAW_GROUP_FOLDER": "test-group"
    ]) {
        let fetchTool = WebFetchTool()
        var didThrow = false
        do {
            _ = try await fetchTool.execute(arguments: [
                "url": .string("https://github.com")
            ])
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }
}

@Test
func testTodoReadReturnsEmptyWhenNoSnapshotExists() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", tempDir.path) {
        let tool = TodoReadTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.stringValue == "No TODO items.")
    }
}

@Test
func testMemoryToolsReadWriteChatAndGlobalScopes() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let chatMemoryFile = tempDir.appendingPathComponent("chat/memory.md")
    let globalMemoryFile = tempDir.appendingPathComponent("global/memory.md")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = FileMemoryStore(chatMemoryFile: chatMemoryFile, globalMemoryFile: globalMemoryFile)
    let writeTool = WriteMemoryTool(store: store)
    let readTool = ReadMemoryTool(store: store)

    let chatWrite = try await writeTool.execute(arguments: [
        "scope": .string("chat"),
        "content": .string("Remember user preference: concise responses."),
        "mode": .string("replace")
    ]).stringValue ?? ""
    #expect(chatWrite.contains("scope=chat"))
    #expect(chatWrite.contains("mode=replace"))

    let chatRead = try await readTool.execute(arguments: [
        "scope": .string("chat")
    ]).stringValue ?? ""
    #expect(chatRead == "Remember user preference: concise responses.")

    _ = try await writeTool.execute(arguments: [
        "scope": .string("global"),
        "content": .string("Shared memory line A"),
        "mode": .string("replace")
    ])
    _ = try await writeTool.execute(arguments: [
        "scope": .string("global"),
        "content": .string("Shared memory line B"),
        "mode": .string("append")
    ])

    let globalRead = try await readTool.execute(arguments: [
        "scope": .string("global")
    ]).stringValue ?? ""
    #expect(globalRead.contains("Shared memory line A"))
    #expect(globalRead.contains("Shared memory line B"))
}

@Test
func testWriteMemoryRejectsInvalidMode() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let store = FileMemoryStore(
        chatMemoryFile: tempDir.appendingPathComponent("chat/memory.md"),
        globalMemoryFile: tempDir.appendingPathComponent("global/memory.md")
    )
    let tool = WriteMemoryTool(store: store)

    do {
        _ = try await tool.execute(arguments: [
            "scope": .string("chat"),
            "content": .string("x"),
            "mode": .string("merge")
        ])
        Issue.record("Expected invalid mode to throw")
    } catch let error as AgentError {
        guard case .invalidToolArguments(let toolName, let reason) = error else {
            Issue.record("Unexpected error type: \(error)")
            return
        }
        #expect(toolName == "write_memory")
        #expect(reason.lowercased().contains("mode"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func testMCPStatusToolFormatsStatusSummary() async throws {
    let status = MCPRuntimeStatus(
        hasConfig: true,
        configuredServerCount: 2,
        loadedServerIDs: ["alpha"],
        loadedToolCount: 3,
        skippedServers: [MCPSkippedServer(id: "beta", reason: .hostRuntimeUnsupported)],
        diagnostics: ["loaded_servers=1", "loaded_tools=3"]
    )
    let tool = MCPStatusTool(status: status)
    let result = try await tool.execute(arguments: [:]).stringValue ?? ""

    #expect(result.contains("Config found: yes"))
    #expect(result.contains("Configured servers: 2"))
    #expect(result.contains("Loaded servers: alpha"))
    #expect(result.contains("Loaded tools: 3"))
    #expect(result.contains("Skipped servers: beta(hostRuntimeUnsupported)"))
}

@Test
func testMCPReloadToolSummarizesHostAndContainerReload() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configURL = tempDir.appendingPathComponent(".mcp.json")
    let config = """
    {
      "mcpServers": {
        "focusrelay": {
          "runtime": "host",
          "transport": "stdio",
          "command": "/opt/homebrew/bin/focusrelay",
          "args": ["serve"]
        },
        "localsmoke": {
          "runtime": "container",
          "transport": "stdio",
          "command": "python3",
          "args": ["/workspace/group/.nanoclaw/mcp/local_smoke_server.py"]
        },
        "skipped": {
          "runtime": "unknown",
          "transport": "stdio",
          "command": "noop"
        }
      }
    }
    """
    try config.write(to: configURL, atomically: true, encoding: .utf8)

    let tool = MCPReloadTool(
        environment: [:],
        hostRequest: { endpoint, payload, _ in
            #expect(endpoint == "bootstrap")
            let servers = payload["servers"] as? [[String: Any]] ?? []
            #expect(servers.count == 1)
            return [
                "ok": true,
                "loadedServerCount": 1,
                "loadedToolCount": 2,
                "servers": [
                    [
                        "id": "focusrelay",
                        "tools": [
                            ["name": "list_tasks"],
                            ["name": "bridge_health_check"]
                        ]
                    ]
                ]
            ]
        },
        configResolver: { _, _ in configURL }
    )

    let output = try await tool.execute(arguments: [:]).stringValue ?? ""
    #expect(output.contains("MCP reload complete."))
    #expect(output.contains("Configured servers: container=1, host=1, skipped=1"))
    #expect(output.contains("Host reload: loaded_servers=1, loaded_tools=2"))
    #expect(output.contains("mcp_focusrelay_list_tasks"))
    #expect(output.contains("mcp_focusrelay_bridge_health_check"))
    #expect(output.contains("Container MCP servers (loaded on next request): localsmoke"))
    #expect(output.contains("skipped(unsupportedRuntime)"))
}

@Test
func testMCPReloadToolFailsWhenConfigMissing() async {
    let tool = MCPReloadTool(
        environment: [:],
        hostRequest: { _, _, _ in
            [:]
        },
        configResolver: { _, _ in nil }
    )

    do {
        _ = try await tool.execute(arguments: [:])
        Issue.record("Expected missing MCP config to throw")
    } catch {
        let text = String(describing: error).lowercased()
        #expect(text.contains("mcp config not found"))
    }
}

@Test
func testTodoWriteAddAndRemoveByIndex() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", tempDir.path) {
        let writeTool = TodoWriteTool()
        let readTool = TodoReadTool()

        _ = try await writeTool.execute(arguments: [
            "action": .string("add"),
            "item": .string("Ship parity tools")
        ])
        _ = try await writeTool.execute(arguments: [
            "action": .string("add"),
            "item": .string("Add skill sync")
        ])

        let beforeRemove = try await readTool.execute(arguments: [:]).stringValue ?? ""
        #expect(beforeRemove.contains("1. Ship parity tools"))
        #expect(beforeRemove.contains("2. Add skill sync"))

        _ = try await writeTool.execute(arguments: [
            "action": .string("remove"),
            "index": .int(1)
        ])

        let afterRemove = try await readTool.execute(arguments: [:]).stringValue ?? ""
        #expect(!afterRemove.contains("Ship parity tools"))
        #expect(afterRemove.contains("1. Add skill sync"))
    }
}

@Test
func testDefaultToolsetIncludesTodoParityTools() async {
    let config = NanoClawConfig(apiKey: "test-key")
    let agent = await NanoClawAgent(
        config: config,
        groupFolder: "test-group",
        chatJid: "telegram_123",
        isMain: false,
        isScheduledTask: false
    )
    let names = Set(agent.tools.map(\.name))
    #expect(names.contains("todo_read"))
    #expect(names.contains("todo_write"))
}

@Test
func testDefaultToolsetIncludesMemoryTools() async {
    let config = NanoClawConfig(apiKey: "test-key")
    let agent = await NanoClawAgent(
        config: config,
        groupFolder: "test-group",
        chatJid: "telegram_123",
        isMain: false,
        isScheduledTask: false
    )
    let names = Set(agent.tools.map(\.name))
    #expect(names.contains("read_memory"))
    #expect(names.contains("write_memory"))
}

@Test
func testGetTaskHistoryReturnsEmptyWhenNoSessionHistory() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await TestEnvironmentLock.shared.withEnvs([
        "NANOCLAW_BASE_PATH": tempDir.path,
        "NANOCLAW_GROUP_FOLDER": "group-a",
        "NANOCLAW_GROUP_ISOLATED_MOUNT": "1"
    ]) {
        let tool = GetTaskHistoryTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.stringValue == "No task history yet.")
    }
}

@Test
func testGetTaskHistoryRespectsLimitAndFormatting() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let session = FileBasedSession(groupFolder: tempDir.path)
    try await session.addItems([
        .user("first prompt"),
        .assistant("first response"),
        .user("second prompt"),
        .assistant("second response")
    ])

    try await TestEnvironmentLock.shared.withEnvs([
        "NANOCLAW_BASE_PATH": tempDir.path,
        "NANOCLAW_GROUP_FOLDER": "group-a",
        "NANOCLAW_GROUP_ISOLATED_MOUNT": "1"
    ]) {
        let tool = GetTaskHistoryTool()
        let result = try await tool.execute(arguments: ["limit": .int(2)])
        let text = result.stringValue ?? ""
        #expect(text.contains("[user] second prompt"))
        #expect(text.contains("[assistant] second response"))
        #expect(!text.contains("first prompt"))
    }
}

@Test
func testDefaultToolsetIncludesGetTaskHistoryTool() async {
    let config = NanoClawConfig(apiKey: "test-key")
    let agent = await NanoClawAgent(
        config: config,
        groupFolder: "test-group",
        chatJid: "telegram_123",
        isMain: false,
        isScheduledTask: false
    )
    let names = Set(agent.tools.map(\.name))
    #expect(names.contains("get_task_history"))
}

@Test
func testExportChatCreatesMarkdownExport() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let session = FileBasedSession(groupFolder: tempDir.path)
    try await session.addItems([
        .user("hello export"),
        .assistant("exported response")
    ])

    try await TestEnvironmentLock.shared.withEnvs([
        "NANOCLAW_BASE_PATH": tempDir.path,
        "NANOCLAW_GROUP_FOLDER": "group-a",
        "NANOCLAW_GROUP_ISOLATED_MOUNT": "1"
    ]) {
        let tool = ExportChatTool()
        let result = try await tool.execute(arguments: ["format": .string("markdown")])
        let output = result.stringValue ?? ""
        #expect(output.contains(".md"))

        guard let pathLine = output.split(separator: "\n").first(where: { $0.contains("Exported chat to ") }) else {
            Issue.record("Missing export path in tool output")
            return
        }
        let exportPath = pathLine.replacingOccurrences(of: "Exported chat to ", with: "")
        #expect(FileManager.default.fileExists(atPath: exportPath))

        let content = try String(contentsOfFile: exportPath, encoding: .utf8)
        #expect(content.contains("hello export"))
        #expect(content.contains("exported response"))
    }
}

@Test
func testDefaultToolsetIncludesExportChatTool() async {
    let config = NanoClawConfig(apiKey: "test-key")
    let agent = await NanoClawAgent(
        config: config,
        groupFolder: "test-group",
        chatJid: "telegram_123",
        isMain: false,
        isScheduledTask: false
    )
    let names = Set(agent.tools.map(\.name))
    #expect(names.contains("export_chat"))
}

@Test
func testSubAgentToolRequiresPrompt() async {
    let tool = SubAgentTool()
    var didThrow = false
    do {
        _ = try await tool.execute(arguments: [:])
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

@Test
func testDefaultToolsetIncludesSubAgentTool() async {
    let config = NanoClawConfig(apiKey: "test-key")
    let agent = await NanoClawAgent(
        config: config,
        groupFolder: "test-group",
        chatJid: "telegram_123",
        isMain: false,
        isScheduledTask: false
    )
    let names = Set(agent.tools.map(\.name))
    #expect(names.contains("sub_agent"))
}

@Test
func testDefaultToolsetIncludesFocusRelayTools() async {
    let config = NanoClawConfig(apiKey: "test-key")
    let agent = await NanoClawAgent(
        config: config,
        groupFolder: "test-group",
        chatJid: "telegram_123",
        isMain: false,
        isScheduledTask: false
    )
    let names = Set(agent.tools.map(\.name))
    #expect(names.contains("focusrelay_inbox_tasks"))
    #expect(names.contains("focusrelay_cli"))
    #expect(names.contains("focusrelay_bridge_health"))
    #expect(names.contains("mcp_host_cli"))
    #expect(names.contains("mcp_reload"))
}

@Test
func testSubAgentToolDelegatesWithPromptContextAndClampedTemperature() async throws {
    let provider = SubAgentTestProvider(response: "delegated-ok")
    let tool = SubAgentTool(
        configLoader: {
            NanoClawConfig(
                apiKey: "test-key",
                provider: .openai,
                model: .gpt52Instant,
                timeout: 90,
                maxTokens: 600
            )
        },
        providerFactory: { _ in provider }
    )

    let output = try await tool.execute(arguments: [
        "prompt": .string("Summarize actor isolation"),
        "context": .string("Focus on migration risks"),
        "temperature": .string("9.9")
    ])

    #expect(output.stringValue == "delegated-ok")
    let prompts = await provider.prompts
    let options = await provider.options
    #expect(prompts.count == 1)
    #expect(options.count == 1)
    #expect(prompts[0].contains("Task:\nSummarize actor isolation"))
    #expect(prompts[0].contains("Additional context:\nFocus on migration risks"))
    #expect(options[0].temperature == 2.0)
    #expect(options[0].maxTokens == 600)
}

@Test
func testSubAgentProviderRegistryReusesProviderForSameConfig() async throws {
    let config = NanoClawConfig(
        apiKey: "shared-key",
        provider: .openai,
        model: .gpt52Instant,
        timeout: 60,
        requestsPerMinuteLimit: 5
    )
    let first = try await SubAgentProviderRegistry.shared.provider(for: config)
    let second = try await SubAgentProviderRegistry.shared.provider(for: config)
    #expect(first === second)
}

@Test
func testListSkillsShowsDiscoveredValidSkills() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let codexHome = tempDir.appendingPathComponent("codex-home")
    let skillsRoot = codexHome.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let validSkillDir = skillsRoot.appendingPathComponent("daily-report")
    try FileManager.default.createDirectory(at: validSkillDir, withIntermediateDirectories: true)
    try """
    # Daily Report

    Generate a concise daily report.
    """.write(
        to: validSkillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let invalidSkillDir = skillsRoot.appendingPathComponent("broken-skill")
    try FileManager.default.createDirectory(at: invalidSkillDir, withIntermediateDirectories: true)
    try "no markdown heading".write(
        to: invalidSkillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let tool = ListSkillsTool()
    let output = try await tool.execute(arguments: [
        "skills_root": .string(skillsRoot.path)
    ]).stringValue ?? ""

    #expect(output.contains("Daily Report"))
    #expect(!output.contains("broken-skill"))
}

@Test
func testActivateSkillMarksSkillAsActiveInListOutput() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let groupRoot = tempDir.appendingPathComponent("group")
    let codexHome = tempDir.appendingPathComponent("codex-home")
    let skillsRoot = codexHome.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: groupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let skillDir = skillsRoot.appendingPathComponent("focus-mode")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try """
    # Focus Mode

    Keep responses concise and action-oriented.
    """.write(
        to: skillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", groupRoot.path) {
        let activateTool = ActivateSkillTool()
        let activation = try await activateTool.execute(arguments: [
            "skill": .string("focus-mode"),
            "skills_root": .string(skillsRoot.path)
        ]).stringValue ?? ""
        #expect(activation.contains("Activated skill"))

        let listTool = ListSkillsTool()
        let listed = try await listTool.execute(arguments: [
            "skills_root": .string(skillsRoot.path)
        ]).stringValue ?? ""
        #expect(listed.contains("[active] Focus Mode"))
    }
}

@Test
func testActivateSkillFailsOnAmbiguousSkillName() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let groupRoot = tempDir.appendingPathComponent("group")
    let skillsRoot = tempDir.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: groupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let skillA = skillsRoot.appendingPathComponent("alpha")
    let skillB = skillsRoot.appendingPathComponent("beta")
    try FileManager.default.createDirectory(at: skillA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skillB, withIntermediateDirectories: true)
    try """
    # Daily Briefing

    Draft a daily briefing.
    """.write(
        to: skillA.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
    try """
    # Daily Briefing

    Another variant.
    """.write(
        to: skillB.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", groupRoot.path) {
        let tool = ActivateSkillTool()
        do {
            _ = try await tool.execute(arguments: [
                "skill": .string("Daily Briefing"),
                "skills_root": .string(skillsRoot.path)
            ])
            Issue.record("Expected ambiguous skill activation to throw")
        } catch {
            let message = String(describing: error).lowercased()
            #expect(message.contains("ambiguous") || message.contains("multiple"))
        }
    }
}

@Test
func testSyncSkillsPrunesMissingActiveSkill() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let groupRoot = tempDir.appendingPathComponent("group")
    let skillsRoot = tempDir.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: groupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let skillDir = skillsRoot.appendingPathComponent("cleanup")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try """
    # Cleanup

    Cleanup workflow helper.
    """.write(
        to: skillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", groupRoot.path) {
        let activateTool = ActivateSkillTool()
        _ = try await activateTool.execute(arguments: [
            "skill": .string("cleanup"),
            "skills_root": .string(skillsRoot.path)
        ])

        try FileManager.default.removeItem(at: skillDir)

        let syncTool = SyncSkillsTool()
        let syncOutput = try await syncTool.execute(arguments: [
            "skills_root": .string(skillsRoot.path)
        ]).stringValue ?? ""
        #expect(syncOutput.contains("removed_stale_active=1"))
    }
}

@Test
func testDeactivateSkillMarksSkillAsInactive() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let groupRoot = tempDir.appendingPathComponent("group")
    let skillsRoot = tempDir.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: groupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let skillDir = skillsRoot.appendingPathComponent("focus-mode")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try """
    # Focus Mode

    Keep responses concise and action-oriented.
    """.write(
        to: skillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    try await TestEnvironmentLock.shared.withEnv("NANOCLAW_BASE_PATH", groupRoot.path) {
        let activateTool = ActivateSkillTool()
        _ = try await activateTool.execute(arguments: [
            "skill": .string("focus-mode"),
            "skills_root": .string(skillsRoot.path)
        ])

        let deactivateTool = DeactivateSkillTool()
        let deactivated = try await deactivateTool.execute(arguments: [
            "skill": .string("focus-mode"),
            "skills_root": .string(skillsRoot.path)
        ]).stringValue ?? ""
        #expect(deactivated.contains("Deactivated skill"))

        let listTool = ListSkillsTool()
        let listed = try await listTool.execute(arguments: [
            "skills_root": .string(skillsRoot.path)
        ]).stringValue ?? ""
        #expect(listed.contains("[inactive] Focus Mode"))
    }
}

@Test
func testDefaultToolsetIncludesSkillsTools() async {
    let config = NanoClawConfig(apiKey: "test-key")
    let agent = await NanoClawAgent(
        config: config,
        groupFolder: "test-group",
        chatJid: "telegram_123",
        isMain: false,
        isScheduledTask: false
    )
    let names = Set(agent.tools.map(\.name))
    #expect(names.contains("list_skills"))
    #expect(names.contains("activate_skill"))
    #expect(names.contains("deactivate_skill"))
    #expect(names.contains("sync_skills"))
}

@Test
func testListSkillsFallsBackToClaudeSkillsRootWhenCodexMissing() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let homeDir = tempDir.appendingPathComponent("home")
    let claudeSkillsRoot = homeDir.appendingPathComponent(".claude/skills")
    try FileManager.default.createDirectory(at: claudeSkillsRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packingSkillDir = claudeSkillsRoot.appendingPathComponent("packing-list")
    try FileManager.default.createDirectory(at: packingSkillDir, withIntermediateDirectories: true)
    try """
    # Packing List

    Help build a travel packing list.
    """.write(
        to: packingSkillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    try await TestEnvironmentLock.shared.withEnvs([
        "HOME": homeDir.path,
        "CODEX_HOME": ""
    ]) {
        let tool = ListSkillsTool()
        let output = try await tool.execute(arguments: [:]).stringValue ?? ""
        #expect(output.contains("Packing List"))
        #expect(output.contains("packing-list"))
    }
}

@Test
func testActivateSkillUsesClaudeSkillsRootByDefault() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let homeDir = tempDir.appendingPathComponent("home")
    let groupRoot = tempDir.appendingPathComponent("group")
    let claudeSkillsRoot = homeDir.appendingPathComponent(".claude/skills")
    try FileManager.default.createDirectory(at: claudeSkillsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: groupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packingSkillDir = claudeSkillsRoot.appendingPathComponent("packing-list")
    try FileManager.default.createDirectory(at: packingSkillDir, withIntermediateDirectories: true)
    try """
    # Packing List

    Help build a travel packing list.
    """.write(
        to: packingSkillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    try await TestEnvironmentLock.shared.withEnvs([
        "HOME": homeDir.path,
        "CODEX_HOME": "",
        "NANOCLAW_BASE_PATH": groupRoot.path
    ]) {
        let activateTool = ActivateSkillTool()
        let activated = try await activateTool.execute(arguments: [
            "skill": .string("packing-list")
        ]).stringValue ?? ""
        #expect(activated.contains("Activated skill"))

        let listTool = ListSkillsTool()
        let listed = try await listTool.execute(arguments: [:]).stringValue ?? ""
        #expect(listed.contains("[active] Packing List"))
    }
}

@Test
func testSkillsContextComposerSelectsActiveSkillAndAppliesBudgetTruncation() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let homeDir = tempDir.appendingPathComponent("home")
    let groupRoot = tempDir.appendingPathComponent("group")
    let claudeSkillsRoot = homeDir.appendingPathComponent(".claude/skills")
    try FileManager.default.createDirectory(at: claudeSkillsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: groupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let skillDir = claudeSkillsRoot.appendingPathComponent("packing-list")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    let longBody = String(repeating: "Pack light shirts and beach items. ", count: 200)
    try """
    # Packing List Generator

    \(longBody)
    """.write(
        to: skillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    try await TestEnvironmentLock.shared.withEnvs([
        "HOME": homeDir.path,
        "CODEX_HOME": "",
        "NANOCLAW_BASE_PATH": groupRoot.path
    ]) {
        let activateTool = ActivateSkillTool()
        _ = try await activateTool.execute(arguments: ["skill": .string("packing-list")])

        let payload = SkillsContextComposer.compose(
            for: "Help me make a packing list for Bali",
            tokenBudget: 120,
            maxSkills: 3,
            autoResolve: true,
            environment: [
                "HOME": homeDir.path,
                "CODEX_HOME": "",
                "NANOCLAW_BASE_PATH": groupRoot.path
            ]
        )

        #expect(payload != nil)
        #expect(payload?.injectedSkillIDs.contains("packing-list") == true)
        #expect(payload?.resolverApplied == true)
        #expect(payload?.truncated == true)
        #expect(payload?.instructionBlock.contains("Packing List Generator") == true)
    }
}

@Test
func testSkillsContextComposerSkipsIrrelevantActiveSkillWhenAutoResolveEnabled() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let homeDir = tempDir.appendingPathComponent("home")
    let groupRoot = tempDir.appendingPathComponent("group")
    let claudeSkillsRoot = homeDir.appendingPathComponent(".claude/skills")
    try FileManager.default.createDirectory(at: claudeSkillsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: groupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let skillDir = claudeSkillsRoot.appendingPathComponent("packing-list")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try """
    # Packing List Generator

    Help users create travel packing lists.
    """.write(
        to: skillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    try await TestEnvironmentLock.shared.withEnvs([
        "HOME": homeDir.path,
        "CODEX_HOME": "",
        "NANOCLAW_BASE_PATH": groupRoot.path
    ]) {
        let activateTool = ActivateSkillTool()
        _ = try await activateTool.execute(arguments: ["skill": .string("packing-list")])

        let payload = SkillsContextComposer.compose(
            for: "Run failed task task-1770913720773-AFDA0B again and show me the error",
            tokenBudget: 400,
            maxSkills: 3,
            autoResolve: true,
            environment: [
                "HOME": homeDir.path,
                "CODEX_HOME": "",
                "NANOCLAW_BASE_PATH": groupRoot.path
            ]
        )

        #expect(payload == nil)
    }
}
