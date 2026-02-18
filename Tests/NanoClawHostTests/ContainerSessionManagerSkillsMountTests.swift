import Foundation
import Testing

@testable import NanoClawHost

@Test
func testResolveHostSkillsRootUsesPassthroughCodexHomeFirst() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanoclaw-host-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let codexHome = temp.appendingPathComponent("codex-home")
    let skills = codexHome.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)

    let resolved = ContainerSessionManager.resolveHostSkillsRoot(
        projectRoot: temp.path,
        passthroughEnvironment: ["CODEX_HOME": codexHome.path],
        homePath: temp.appendingPathComponent("home").path
    )

    #expect(resolved == skills.path)
}

@Test
func testResolveHostSkillsRootFallsBackToProjectDotCodex() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanoclaw-host-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let projectSkills = temp.appendingPathComponent(".codex").appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: projectSkills, withIntermediateDirectories: true)

    let resolved = ContainerSessionManager.resolveHostSkillsRoot(
        projectRoot: temp.path,
        passthroughEnvironment: [:],
        homePath: temp.appendingPathComponent("home").path
    )

    #expect(resolved == projectSkills.path)
}

@Test
func testResolveHostSkillsRootFallsBackToHomeDotCodex() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanoclaw-host-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let home = temp.appendingPathComponent("home")
    let homeSkills = home.appendingPathComponent(".codex").appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: homeSkills, withIntermediateDirectories: true)

    let resolved = ContainerSessionManager.resolveHostSkillsRoot(
        projectRoot: temp.path,
        passthroughEnvironment: [:],
        homePath: home.path
    )

    #expect(resolved == homeSkills.path)
}

@Test
func testResolveHostSkillsRootReturnsNilWhenNoCandidateExists() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanoclaw-host-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let resolved = ContainerSessionManager.resolveHostSkillsRoot(
        projectRoot: temp.path,
        passthroughEnvironment: [:],
        homePath: temp.appendingPathComponent("home").path
    )

    #expect(resolved == nil)
}

@Test
func testResolveHostClaudeSkillsRootFindsHomeClaudeSkills() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanoclaw-host-claude-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let home = temp.appendingPathComponent("home")
    let claudeSkills = home.appendingPathComponent(".claude").appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)

    let resolved = ContainerSessionManager.resolveHostClaudeSkillsRoot(homePath: home.path)
    #expect(resolved == claudeSkills.path)
}

@Test
func testResolveHostClaudeSkillsRootReturnsNilWhenMissing() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanoclaw-host-claude-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let resolved = ContainerSessionManager.resolveHostClaudeSkillsRoot(homePath: temp.path)
    #expect(resolved == nil)
}
