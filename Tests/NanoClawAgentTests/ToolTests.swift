import Testing
import Foundation
import SwiftAgents
@testable import NanoClawAgent

private struct OverlaySnapshot: Codable {
    let version: Int
    let allow: [String]
    let deny: [String]
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
