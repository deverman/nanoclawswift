import Foundation

public enum SlashCommand: Sendable, Equatable {
    case tasks
    case schedule(time: String, prompt: String)
    case pause(taskID: String)
    case resume(taskID: String)
    case cancel(taskID: String)
    case skills
    case reloadSkills
    case mcpStatus
    case mcpReload(configPath: String?)
    case mcpCLI(serverID: String, args: [String])
    case more(limit: Int?)
    case help
}

public struct SlashCommandUsageError: Error, Sendable, Equatable {
    public let command: String
    public let usage: String
    public let message: String

    public init(command: String, usage: String, message: String) {
        self.command = command
        self.usage = usage
        self.message = message
    }
}

public enum SlashCommandParseResult: Sendable, Equatable {
    case notCommand
    case command(SlashCommand)
    case invalid(SlashCommandUsageError)
    case unknown(name: String)
}

public enum SlashCommandParser {
    public static func parse(_ raw: String) -> SlashCommandParseResult {
        let trimmedLeading = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmedLeading.first else {
            return .notCommand
        }
        guard first == "/" else {
            return .notCommand
        }

        let body = String(trimmedLeading.dropFirst())
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid(
                SlashCommandUsageError(
                    command: "/help",
                    usage: "/help",
                    message: "Missing command name."
                )
            )
        }

        guard let tokens = tokenize(body) else {
            let commandToken = body
                .split(whereSeparator: \.isWhitespace)
                .first
                .map { "/\($0.lowercased())" } ?? "/help"
            let usage = usageFor(command: commandToken)
            return .invalid(
                SlashCommandUsageError(
                    command: commandToken,
                    usage: usage,
                    message: "Unterminated quote in command arguments."
                )
            )
        }
        guard let firstToken = tokens.first else {
            return .invalid(
                SlashCommandUsageError(
                    command: "/help",
                    usage: "/help",
                    message: "Missing command name."
                )
            )
        }

        let commandName = "/\(firstToken.lowercased())"
        let args = Array(tokens.dropFirst())
        switch commandName {
        case "/tasks":
            guard args.isEmpty else {
                return invalid(command: commandName, message: "Unexpected arguments.")
            }
            return .command(.tasks)
        case "/schedule":
            guard args.count >= 2 else {
                return invalid(command: commandName, message: "Missing time and prompt.")
            }
            let time = args[0]
            guard isHHMM(time) else {
                return invalid(command: commandName, message: "Invalid time format; expected HH:MM.")
            }
            let prompt = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                return invalid(command: commandName, message: "Missing prompt.")
            }
            return .command(.schedule(time: time, prompt: prompt))
        case "/pause":
            guard args.count == 1 else {
                return invalid(command: commandName, message: "Expected exactly one task ID.")
            }
            return .command(.pause(taskID: args[0]))
        case "/resume":
            guard args.count == 1 else {
                return invalid(command: commandName, message: "Expected exactly one task ID.")
            }
            return .command(.resume(taskID: args[0]))
        case "/cancel":
            guard args.count == 1 else {
                return invalid(command: commandName, message: "Expected exactly one task ID.")
            }
            return .command(.cancel(taskID: args[0]))
        case "/skills":
            guard args.isEmpty else {
                return invalid(command: commandName, message: "Unexpected arguments.")
            }
            return .command(.skills)
        case "/reload-skills":
            guard args.isEmpty else {
                return invalid(command: commandName, message: "Unexpected arguments.")
            }
            return .command(.reloadSkills)
        case "/mcp-status":
            guard args.isEmpty else {
                return invalid(command: commandName, message: "Unexpected arguments.")
            }
            return .command(.mcpStatus)
        case "/mcp-reload":
            guard args.count <= 1 else {
                return invalid(command: commandName, message: "Expected zero or one config path argument.")
            }
            let configPath = args.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .command(.mcpReload(configPath: configPath?.isEmpty == true ? nil : configPath))
        case "/mcp-cli":
            guard args.count >= 1 else {
                return invalid(command: commandName, message: "Missing server_id.")
            }
            let serverID = args[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverID.isEmpty else {
                return invalid(command: commandName, message: "Missing server_id.")
            }
            return .command(.mcpCLI(serverID: serverID, args: Array(args.dropFirst())))
        case "/more":
            guard args.count <= 1 else {
                return invalid(command: commandName, message: "Expected no argument or one integer page size.")
            }
            if args.isEmpty {
                return .command(.more(limit: nil))
            }
            guard let parsed = Int(args[0]), (1...100).contains(parsed) else {
                return invalid(command: commandName, message: "Page size must be an integer between 1 and 100.")
            }
            return .command(.more(limit: parsed))
        case "/help", "/commands":
            guard args.isEmpty else {
                return invalid(command: commandName, message: "Unexpected arguments.")
            }
            return .command(.help)
        default:
            return .unknown(name: commandName)
        }
    }

    private static func invalid(command: String, message: String) -> SlashCommandParseResult {
        .invalid(
            SlashCommandUsageError(
                command: command,
                usage: usageFor(command: command),
                message: message
            )
        )
    }

    private static func usageFor(command: String) -> String {
        switch command {
        case "/tasks":
            return "/tasks"
        case "/schedule":
            return "/schedule <HH:MM> <prompt...>"
        case "/pause":
            return "/pause <task_id>"
        case "/resume":
            return "/resume <task_id>"
        case "/cancel":
            return "/cancel <task_id>"
        case "/skills":
            return "/skills"
        case "/reload-skills":
            return "/reload-skills"
        case "/mcp-status":
            return "/mcp-status"
        case "/mcp-reload":
            return "/mcp-reload [config_path]"
        case "/mcp-cli":
            return "/mcp-cli <server_id> [args...]"
        case "/more":
            return "/more [n]"
        case "/help":
            return "/help"
        case "/commands":
            return "/commands"
        default:
            return "/help"
        }
    }

    private static func tokenize(_ body: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        func appendCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for ch in body {
            if let active = quote {
                if ch == active {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }

            if ch.isWhitespace {
                appendCurrent()
                continue
            }
            current.append(ch)
        }

        guard quote == nil else {
            return nil
        }

        appendCurrent()
        return tokens
    }

    private static func isHHMM(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return false
        }
        return true
    }
}
