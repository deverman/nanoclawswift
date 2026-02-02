import Testing
import Foundation
@testable import NanoClawAgent

@Test
func testFileBasedSessionPersistsMessages() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    setenv("NANOCLAW_BASE_PATH", tempDir.path, 1)
    defer { unsetenv("NANOCLAW_BASE_PATH") }

    let session = FileBasedSession(groupFolder: "group-a")
    try await session.addItems([
        MemoryMessage.user("Hello"),
        MemoryMessage.assistant("Hi")
    ])

    let items = try await session.getItems(limit: nil)
    #expect(items.count == 2)
    #expect(items.first?.content == "Hello")

    let sessionFile = tempDir.appendingPathComponent("group-a/.nanoclaw/session.json")
    #expect(FileManager.default.fileExists(atPath: sessionFile.path))

    let attributes = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
    if let perms = attributes[.posixPermissions] as? NSNumber {
        #expect(perms.intValue & 0o777 == 0o600)
    }
}

@Test
func testFileBasedSessionPopItem() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    setenv("NANOCLAW_BASE_PATH", tempDir.path, 1)
    defer { unsetenv("NANOCLAW_BASE_PATH") }

    let session = FileBasedSession(groupFolder: "group-b")
    try await session.addItems([
        MemoryMessage.user("One"),
        MemoryMessage.assistant("Two")
    ])

    let popped = try await session.popItem()
    #expect(popped?.content == "Two")

    let remaining = try await session.getItems(limit: nil)
    #expect(remaining.count == 1)
}
