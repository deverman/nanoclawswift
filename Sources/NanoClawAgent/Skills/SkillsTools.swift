import Configuration
import Foundation
import SwiftAgents

struct SkillDescriptor: Sendable {
    let id: String
    let name: String
    let path: String
    let summary: String
    let isValid: Bool
    let validationError: String?
}

public struct SkillsContextPayload: Sendable {
    public let instructionBlock: String
    public let injectedSkillIDs: [String]
    public let injectedSkillNames: [String]
    public let truncated: Bool
    public let resolverApplied: Bool
    public let selectedByResolver: Bool

    public init(
        instructionBlock: String,
        injectedSkillIDs: [String],
        injectedSkillNames: [String],
        truncated: Bool,
        resolverApplied: Bool,
        selectedByResolver: Bool
    ) {
        self.instructionBlock = instructionBlock
        self.injectedSkillIDs = injectedSkillIDs
        self.injectedSkillNames = injectedSkillNames
        self.truncated = truncated
        self.resolverApplied = resolverApplied
        self.selectedByResolver = selectedByResolver
    }
}

private struct ActiveSkillsState: Codable, Sendable {
    var activeSkillIDs: [String]
}

enum SkillsCatalogError: Error, LocalizedError {
    case missingSkillsRoot
    case skillsRootNotFound(String)
    case skillNotFound(String)
    case ambiguousSkill(String)
    case invalidSkill(String)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSkillsRoot:
            return "Skills root is not configured. Set CODEX_HOME/HOME or pass skills_root."
        case .skillsRootNotFound(let path):
            return "Skills root not found: \(path)"
        case .skillNotFound(let name):
            return "Skill not found: \(name)"
        case .ambiguousSkill(let name):
            return "Ambiguous skill identifier: \(name). Multiple skills match this name."
        case .invalidSkill(let message):
            return "Skill is invalid: \(message)"
        case .persistenceFailed(let message):
            return "Failed to persist active skills: \(message)"
        }
    }
}

private struct SkillsRuntimeConfig {
    let codeXHome: String
    let home: String
    let basePath: String
    let skillContextTokenBudget: Int
    let skillContextMaxSkills: Int
    let skillAutoResolveEnabled: Bool

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SkillsRuntimeConfig {
        if #available(macOS 15.0, iOS 18.0, *) {
            let reader = ConfigReader(
                provider: EnvironmentVariablesProvider(environmentVariables: environment)
            )
            return SkillsRuntimeConfig(
                codeXHome: reader.string(forKey: ConfigKey("CODEX_HOME"), default: ""),
                home: reader.string(forKey: ConfigKey("HOME"), default: ""),
                basePath: reader.string(forKey: ConfigKey("NANOCLAW_BASE_PATH"), default: "/workspace/group"),
                skillContextTokenBudget: max(100, reader.int(forKey: ConfigKey("NANOCLAW_SKILLS_CONTEXT_TOKEN_BUDGET"), default: 600)),
                skillContextMaxSkills: max(1, min(reader.int(forKey: ConfigKey("NANOCLAW_SKILLS_CONTEXT_MAX"), default: 3), 12)),
                skillAutoResolveEnabled: reader.bool(forKey: ConfigKey("NANOCLAW_SKILLS_AUTO_RESOLVE"), default: true)
            )
        }

        return SkillsRuntimeConfig(
            codeXHome: environment["CODEX_HOME"] ?? "",
            home: environment["HOME"] ?? "",
            basePath: environment["NANOCLAW_BASE_PATH"] ?? "/workspace/group",
            skillContextTokenBudget: max(100, Int(environment["NANOCLAW_SKILLS_CONTEXT_TOKEN_BUDGET"] ?? "") ?? 600),
            skillContextMaxSkills: max(1, min(Int(environment["NANOCLAW_SKILLS_CONTEXT_MAX"] ?? "") ?? 3, 12)),
            skillAutoResolveEnabled: Bool.parse(environment["NANOCLAW_SKILLS_AUTO_RESOLVE"], defaultValue: true)
        )
    }

    var defaultSkillsRoots: [String] {
        var roots: [String] = []

        let trimmedCodexHome = codeXHome.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCodexHome.isEmpty {
            roots.append("\(trimmedCodexHome)/skills")
        }

        let trimmedHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHome.isEmpty {
            roots.append("\(trimmedHome)/.codex/skills")
            roots.append("\(trimmedHome)/.claude/skills")
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for root in roots {
            let normalized = root.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty || seen.contains(normalized) { continue }
            seen.insert(normalized)
            deduped.append(normalized)
        }
        return deduped
    }
}

private extension Bool {
    static func parse(_ raw: String?, defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}

private enum SkillsCatalog {
    static func resolveSkillsRoots(arguments: [String: SendableValue]) throws -> [String] {
        if let explicit = arguments["skills_root"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return [explicit]
        }

        let config = SkillsRuntimeConfig.load()
        let inferred = config.defaultSkillsRoots
        guard !inferred.isEmpty else {
            throw SkillsCatalogError.missingSkillsRoot
        }
        return inferred
    }

    static func discover(skillsRootPaths: [String]) throws -> [SkillDescriptor] {
        var discoveredByID: [String: SkillDescriptor] = [:]
        var hasAtLeastOneValidRoot = false

        for root in skillsRootPaths {
            let rootURL = URL(fileURLWithPath: root)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else { continue }
            hasAtLeastOneValidRoot = true

            let files = skillMarkdownFiles(in: rootURL)
            for file in files {
                let descriptor = parseSkillDescriptor(skillFileURL: file, rootURL: rootURL)
                if discoveredByID[descriptor.id] == nil {
                    discoveredByID[descriptor.id] = descriptor
                }
            }
        }

        guard hasAtLeastOneValidRoot else {
            throw SkillsCatalogError.skillsRootNotFound(skillsRootPaths.joined(separator: ", "))
        }

        return Array(discoveredByID.values).sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.id < rhs.id
            }
            return lhs.name < rhs.name
        }
    }

    static func discover(skillsRootPath: String) throws -> [SkillDescriptor] {
        let rootURL = URL(fileURLWithPath: skillsRootPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SkillsCatalogError.skillsRootNotFound(skillsRootPath)
        }

        let files = skillMarkdownFiles(in: rootURL)
        return files.map { parseSkillDescriptor(skillFileURL: $0, rootURL: rootURL) }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name {
                    return lhs.id < rhs.id
                }
                return lhs.name < rhs.name
            }
    }

    static func loadActiveIDs(basePath: String) throws -> Set<String> {
        let path = activeSkillsPath(basePath: basePath)
        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if data.isEmpty {
                return []
            }
            let decoded = try JSONDecoder().decode(ActiveSkillsState.self, from: data)
            return Set(decoded.activeSkillIDs)
        } catch {
            throw SkillsCatalogError.persistenceFailed(error.localizedDescription)
        }
    }

    static func saveActiveIDs(_ ids: Set<String>, basePath: String) throws {
        let path = activeSkillsPath(basePath: basePath)
        let fileURL = URL(fileURLWithPath: path)
        let dirURL = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dirURL.path) {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        do {
            let payload = ActiveSkillsState(activeSkillIDs: Array(ids).sorted())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw SkillsCatalogError.persistenceFailed(error.localizedDescription)
        }
    }

    static func activateSkill(
        identifier: String,
        skillsRootPaths: [String],
        basePath: String
    ) throws -> SkillDescriptor {
        let skills = try discover(skillsRootPaths: skillsRootPaths)
        let matches = matchingSkills(identifier: identifier, skills: skills)
        guard !matches.isEmpty else {
            throw SkillsCatalogError.skillNotFound(identifier)
        }
        guard matches.count == 1 else {
            throw SkillsCatalogError.ambiguousSkill(identifier)
        }
        let selected = matches[0]
        guard selected.isValid else {
            throw SkillsCatalogError.invalidSkill("\(selected.id): \(selected.validationError ?? "invalid SKILL.md")")
        }

        var active = try loadActiveIDs(basePath: basePath)
        active.insert(selected.id)
        try saveActiveIDs(active, basePath: basePath)
        return selected
    }

    static func sync(
        skillsRootPaths: [String],
        basePath: String
    ) throws -> (total: Int, valid: Int, invalid: Int, active: Int, removedStaleActive: Int) {
        let skills = try discover(skillsRootPaths: skillsRootPaths)
        let validIDs = Set(skills.filter(\.isValid).map(\.id))
        var active = try loadActiveIDs(basePath: basePath)
        let before = active.count
        active = active.intersection(validIDs)
        let removed = max(0, before - active.count)
        try saveActiveIDs(active, basePath: basePath)
        return (
            total: skills.count,
            valid: skills.filter(\.isValid).count,
            invalid: skills.filter { !$0.isValid }.count,
            active: active.count,
            removedStaleActive: removed
        )
    }

    static func deactivateSkill(
        identifier: String,
        skillsRootPaths: [String],
        basePath: String
    ) throws -> (skill: SkillDescriptor, wasActive: Bool) {
        let skills = try discover(skillsRootPaths: skillsRootPaths)
        let matches = matchingSkills(identifier: identifier, skills: skills)
        guard !matches.isEmpty else {
            throw SkillsCatalogError.skillNotFound(identifier)
        }
        guard matches.count == 1 else {
            throw SkillsCatalogError.ambiguousSkill(identifier)
        }

        let selected = matches[0]
        var active = try loadActiveIDs(basePath: basePath)
        let wasActive = active.contains(selected.id)
        active.remove(selected.id)
        try saveActiveIDs(active, basePath: basePath)
        return (selected, wasActive)
    }

    private static func activeSkillsPath(basePath: String) -> String {
        "\(basePath)/.nanoclaw/active-skills.json"
    }

    private static func skillMarkdownFiles(in rootURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == "SKILL.md" {
                files.append(item)
            }
        }
        return files
    }

    private static func parseSkillDescriptor(skillFileURL: URL, rootURL: URL) -> SkillDescriptor {
        let parentURL = skillFileURL.deletingLastPathComponent()
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let parentComponents = parentURL.standardizedFileURL.pathComponents
        let relativeComponents = parentComponents.dropFirst(rootComponents.count)
        let relativeParent = relativeComponents.joined(separator: "/")
        let id = relativeParent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = parentURL.lastPathComponent

        guard let raw = try? String(contentsOf: skillFileURL, encoding: .utf8) else {
            return SkillDescriptor(
                id: id.isEmpty ? fallbackName : id,
                name: fallbackName,
                path: skillFileURL.path,
                summary: "",
                isValid: false,
                validationError: "Unable to read SKILL.md"
            )
        }

        let lines = raw.components(separatedBy: .newlines)
        let titleLine = lines.first { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("# ")
        }

        guard let titleLine else {
            return SkillDescriptor(
                id: id.isEmpty ? fallbackName : id,
                name: fallbackName,
                path: skillFileURL.path,
                summary: "",
                isValid: false,
                validationError: "Missing top-level '# ' heading"
            )
        }

        let parsedName = titleLine.replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = lines.first { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return SkillDescriptor(
            id: id.isEmpty ? fallbackName : id,
            name: parsedName.isEmpty ? fallbackName : parsedName,
            path: skillFileURL.path,
            summary: summary,
            isValid: true,
            validationError: nil
        )
    }

    private static func matchingSkills(identifier: String, skills: [SkillDescriptor]) -> [SkillDescriptor] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        return skills.filter { skill in
            skill.id.lowercased() == lowered || skill.name.lowercased() == lowered
        }
    }
}

public enum SkillsContextComposer {
    public static func compose(
        for input: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SkillsContextPayload? {
        let runtime = SkillsRuntimeConfig.load(environment: environment)
        return compose(
            for: input,
            tokenBudget: runtime.skillContextTokenBudget,
            maxSkills: runtime.skillContextMaxSkills,
            autoResolve: runtime.skillAutoResolveEnabled,
            environment: environment
        )
    }

    static func compose(
        for input: String,
        tokenBudget: Int,
        maxSkills: Int,
        autoResolve: Bool,
        environment: [String: String]
    ) -> SkillsContextPayload? {
        let runtime = SkillsRuntimeConfig.load(environment: environment)
        let skillsRoots = (try? SkillsCatalog.resolveSkillsRoots(arguments: [:])) ?? runtime.defaultSkillsRoots
        guard !skillsRoots.isEmpty else { return nil }
        let discovered = (try? SkillsCatalog.discover(skillsRootPaths: skillsRoots)) ?? []
        guard !discovered.isEmpty else { return nil }
        let activeIDs = (try? SkillsCatalog.loadActiveIDs(basePath: runtime.basePath)) ?? []
        guard !activeIDs.isEmpty else { return nil }

        let activeSkills = discovered.filter { $0.isValid && activeIDs.contains($0.id) }
        guard !activeSkills.isEmpty else { return nil }

        let resolvedMaxSkills = max(1, min(maxSkills, 12))
        let resolvedBudget = max(100, tokenBudget)
        let resolverInput = input.lowercased()
        let selected: [SkillDescriptor]
        let selectedByResolver: Bool
        if autoResolve {
            let ranked = activeSkills
                .map { skill in (skill, score(skill: skill, input: resolverInput)) }
                .sorted { lhs, rhs in
                    if lhs.1 == rhs.1 { return lhs.0.name < rhs.0.name }
                    return lhs.1 > rhs.1
                }
            let positive = ranked.filter { $0.1 > 0 }.map(\.0)
            if positive.isEmpty {
                selected = Array(activeSkills.sorted { $0.name < $1.name }.prefix(resolvedMaxSkills))
                selectedByResolver = false
            } else {
                selected = Array(positive.prefix(resolvedMaxSkills))
                selectedByResolver = true
            }
        } else {
            selected = Array(activeSkills.sorted { $0.name < $1.name }.prefix(resolvedMaxSkills))
            selectedByResolver = false
        }

        guard !selected.isEmpty else { return nil }

        let maxChars = resolvedBudget * 4
        var remainingChars = maxChars
        var lines: [String] = ["## Active Skills Context"]
        var injectedIDs: [String] = []
        var injectedNames: [String] = []
        var truncated = false

        for skill in selected {
            guard remainingChars > 0 else {
                truncated = true
                break
            }
            let content = (try? String(contentsOfFile: skill.path, encoding: .utf8)) ?? ""
            let header = "### \(skill.name) (\(skill.id))"
            let block = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let section = block.isEmpty ? header : "\(header)\n\(block)"
            if section.count <= remainingChars {
                lines.append(section)
                remainingChars -= section.count
                injectedIDs.append(skill.id)
                injectedNames.append(skill.name)
                continue
            }

            let allowed = max(0, remainingChars - header.count - 2)
            let clipped = String(block.prefix(allowed))
            lines.append("\(header)\n\(clipped)")
            injectedIDs.append(skill.id)
            injectedNames.append(skill.name)
            truncated = true
            remainingChars = 0
        }

        guard injectedIDs.isEmpty == false else { return nil }
        if truncated {
            lines.append("_Skill context truncated to fit token budget._")
        }

        return SkillsContextPayload(
            instructionBlock: lines.joined(separator: "\n\n"),
            injectedSkillIDs: injectedIDs,
            injectedSkillNames: injectedNames,
            truncated: truncated,
            resolverApplied: autoResolve,
            selectedByResolver: selectedByResolver
        )
    }

    private static func score(skill: SkillDescriptor, input: String) -> Int {
        let queryTokens = Set(
            input.split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.count >= 3 }
        )
        guard !queryTokens.isEmpty else { return 0 }
        let corpus = "\(skill.id) \(skill.name) \(skill.summary)".lowercased()
        var score = 0
        for token in queryTokens where corpus.contains(token) {
            score += 1
        }
        return score
    }
}

public struct ListSkillsTool: Tool, Sendable {
    public let name = "list_skills"
    public let description = "Lists available Anthropic SKILL.md skills and active status"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "skills_root", description: "Optional absolute path to skills root (default: CODEX_HOME/skills, ~/.codex/skills, ~/.claude/skills)", type: .string, isRequired: false),
        ToolParameter(name: "include_invalid", description: "Include invalid skills in output (default false)", type: .bool, isRequired: false, defaultValue: .bool(false))
    ]

    public func execute(arguments: [String : SendableValue]) async throws -> SendableValue {
        let skillsRoots = try SkillsCatalog.resolveSkillsRoots(arguments: arguments)
        let skills = try SkillsCatalog.discover(skillsRootPaths: skillsRoots)
        let includeInvalid = arguments["include_invalid"]?.boolValue ?? false
        let runtime = SkillsRuntimeConfig.load()
        let activeIDs = try SkillsCatalog.loadActiveIDs(basePath: runtime.basePath)

        let filtered = includeInvalid ? skills : skills.filter(\.isValid)
        guard !filtered.isEmpty else {
            return .string("No skills found.")
        }

        let lines = filtered.map { skill in
            let status: String
            if !skill.isValid {
                status = "[invalid]"
            } else if activeIDs.contains(skill.id) {
                status = "[active]"
            } else {
                status = "[inactive]"
            }
            if let validationError = skill.validationError, !validationError.isEmpty {
                return "\(status) \(skill.name) (\(skill.id)) - \(validationError)"
            }
            if !skill.summary.isEmpty {
                return "\(status) \(skill.name) (\(skill.id)) - \(skill.summary)"
            }
            return "\(status) \(skill.name) (\(skill.id))"
        }

        return .string(lines.joined(separator: "\n"))
    }
}

public struct ActivateSkillTool: Tool, Sendable {
    public let name = "activate_skill"
    public let description = "Activates a discovered skill for the current group session context"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "skill", description: "Skill id or exact skill name", type: .string),
        ToolParameter(name: "skills_root", description: "Optional absolute path to skills root (default: CODEX_HOME/skills, ~/.codex/skills, ~/.claude/skills)", type: .string, isRequired: false)
    ]

    public func execute(arguments: [String : SendableValue]) async throws -> SendableValue {
        guard let skillIdentifier = arguments["skill"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !skillIdentifier.isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing skill parameter")
        }

        let skillsRoots = try SkillsCatalog.resolveSkillsRoots(arguments: arguments)
        let runtime = SkillsRuntimeConfig.load()
        let activated = try SkillsCatalog.activateSkill(
            identifier: skillIdentifier,
            skillsRootPaths: skillsRoots,
            basePath: runtime.basePath
        )
        return .string("Activated skill \(activated.name) (\(activated.id))")
    }
}

public struct SyncSkillsTool: Tool, Sendable {
    public let name = "sync_skills"
    public let description = "Refreshes skills catalog and prunes stale active skill references"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "skills_root", description: "Optional absolute path to skills root (default: CODEX_HOME/skills, ~/.codex/skills, ~/.claude/skills)", type: .string, isRequired: false)
    ]

    public func execute(arguments: [String : SendableValue]) async throws -> SendableValue {
        let skillsRoots = try SkillsCatalog.resolveSkillsRoots(arguments: arguments)
        let runtime = SkillsRuntimeConfig.load()
        let stats = try SkillsCatalog.sync(skillsRootPaths: skillsRoots, basePath: runtime.basePath)
        return .string(
            "synced_skills total=\(stats.total) valid=\(stats.valid) invalid=\(stats.invalid) active=\(stats.active) removed_stale_active=\(stats.removedStaleActive)"
        )
    }
}

public struct DeactivateSkillTool: Tool, Sendable {
    public let name = "deactivate_skill"
    public let description = "Deactivates a discovered skill for the current group session context"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "skill", description: "Skill id or exact skill name", type: .string),
        ToolParameter(name: "skills_root", description: "Optional absolute path to skills root (default: CODEX_HOME/skills, ~/.codex/skills, ~/.claude/skills)", type: .string, isRequired: false)
    ]

    public func execute(arguments: [String : SendableValue]) async throws -> SendableValue {
        guard let skillIdentifier = arguments["skill"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !skillIdentifier.isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing skill parameter")
        }

        let skillsRoots = try SkillsCatalog.resolveSkillsRoots(arguments: arguments)
        let runtime = SkillsRuntimeConfig.load()
        let result = try SkillsCatalog.deactivateSkill(
            identifier: skillIdentifier,
            skillsRootPaths: skillsRoots,
            basePath: runtime.basePath
        )
        if result.wasActive {
            return .string("Deactivated skill \(result.skill.name) (\(result.skill.id))")
        }
        return .string("Skill \(result.skill.name) (\(result.skill.id)) was already inactive")
    }
}
