import Testing
import Foundation
import SwiftAgents
@testable import NanoClawAgent

@Test
func testFileBasedSessionPersistsMessages() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let groupPath = tempDir.appendingPathComponent("group-a").path
    let session = FileBasedSession(groupFolder: groupPath)
    try await session.addItems([
        MemoryMessage.user("Hello"),
        MemoryMessage.assistant("Hi")
    ])

    let items = try await session.getItems(limit: nil)
    #expect(items.count == 2)
    #expect(items.first?.content == "Hello")

    let sessionFile = URL(fileURLWithPath: groupPath).appendingPathComponent(".nanoclaw/session.json")
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
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let groupPath = tempDir.appendingPathComponent("group-b").path
    let session = FileBasedSession(groupFolder: groupPath)
    try await session.addItems([
        MemoryMessage.user("One"),
        MemoryMessage.assistant("Two")
    ])

    let popped = try await session.popItem()
    #expect(popped?.content == "Two")

    let remaining = try await session.getItems(limit: nil)
    #expect(remaining.count == 1)
}

@Test
func testFileBasedSessionRecoversFromMalformedJson() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let groupPath = tempDir.appendingPathComponent("group-c")
    let dotNano = groupPath.appendingPathComponent(".nanoclaw")
    try FileManager.default.createDirectory(at: dotNano, withIntermediateDirectories: true)

    let sessionFile = dotNano.appendingPathComponent("session.json")
    try "{not-json".write(to: sessionFile, atomically: true, encoding: .utf8)

    let session = FileBasedSession(groupFolder: groupPath.path)
    let items = try await session.getItems(limit: nil)
    #expect(items.isEmpty)

    let repairedData = try Data(contentsOf: sessionFile)
    let decoded = try JSONDecoder().decode([MemoryMessage].self, from: repairedData)
    #expect(decoded.isEmpty)
}

@Test
func testFileBasedSessionSkipsConsecutiveDuplicateMessages() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let groupPath = tempDir.appendingPathComponent("group-d").path
    let session = FileBasedSession(groupFolder: groupPath)

    let repeated = MemoryMessage.user("Please use the list_skills tool")
    try await session.addItems([repeated, repeated])

    let items = try await session.getItems(limit: nil)
    #expect(items.count == 1)
    #expect(items.first?.content == "Please use the list_skills tool")
}
