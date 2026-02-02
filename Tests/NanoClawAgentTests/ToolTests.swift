import Testing
import Foundation
@testable import NanoClawAgent

@Test
func testReadWriteTools() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    setenv("NANOCLAW_BASE_PATH", tempDir.path, 1)
    defer { unsetenv("NANOCLAW_BASE_PATH") }

    let write = WriteTool(filePath: "notes.txt", content: "Hello", append: false)
    _ = try await write.execute()

    let read = ReadTool(filePath: "notes.txt", limit: nil)
    let content = try await read.execute()
    #expect(content == "Hello")
}

@Test
func testEditTool() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    setenv("NANOCLAW_BASE_PATH", tempDir.path, 1)
    defer { unsetenv("NANOCLAW_BASE_PATH") }

    let write = WriteTool(filePath: "edit.txt", content: "Hello World", append: false)
    _ = try await write.execute()

    let edit = EditTool(filePath: "edit.txt", find: "World", replace: "Swift", useRegex: false)
    _ = try await edit.execute()

    let read = ReadTool(filePath: "edit.txt", limit: nil)
    let content = try await read.execute()
    #expect(content == "Hello Swift")
}

@Test
func testGlobAndGrep() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    setenv("NANOCLAW_BASE_PATH", tempDir.path, 1)
    defer { unsetenv("NANOCLAW_BASE_PATH") }

    let writeA = WriteTool(filePath: "a.txt", content: "alpha", append: false)
    let writeB = WriteTool(filePath: "b.txt", content: "beta", append: false)
    _ = try await writeA.execute()
    _ = try await writeB.execute()

    let glob = GlobTool(pattern: "*.txt")
    let results = try await glob.execute()
    #expect(results.contains("a.txt"))
    #expect(results.contains("b.txt"))

    let grep = GrepTool(pattern: "alpha", filePattern: "*.txt", useRegex: false)
    let matches = try await grep.execute()
    #expect(matches.contains("a.txt"))
}
