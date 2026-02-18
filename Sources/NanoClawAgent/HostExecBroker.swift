import Foundation

public struct HostExecRequest: Sendable, Equatable {
    public let command: String
    public let arguments: [String]
    public let hasExplicitApproval: Bool
    public let requestID: String

    public init(
        command: String,
        arguments: [String],
        hasExplicitApproval: Bool,
        requestID: String
    ) {
        self.command = command
        self.arguments = arguments
        self.hasExplicitApproval = hasExplicitApproval
        self.requestID = requestID
    }
}

public struct HostExecResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationMs: Int

    public init(exitCode: Int32, stdout: String, stderr: String, durationMs: Int) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.durationMs = durationMs
    }
}

public enum HostExecAuditReason: String, Sendable, Equatable {
    case notAllowlisted
    case approvalRequired
    case executed
    case executionFailed
}

public struct HostExecAuditEntry: Sendable, Equatable {
    public let requestID: String
    public let command: String
    public let arguments: [String]
    public let allowed: Bool
    public let reason: HostExecAuditReason
    public let exitCode: Int32?
    public let timestamp: Date

    public init(
        requestID: String,
        command: String,
        arguments: [String],
        allowed: Bool,
        reason: HostExecAuditReason,
        exitCode: Int32?,
        timestamp: Date = Date()
    ) {
        self.requestID = requestID
        self.command = command
        self.arguments = arguments
        self.allowed = allowed
        self.reason = reason
        self.exitCode = exitCode
        self.timestamp = timestamp
    }
}

public protocol HostExecAuditSink: Sendable {
    func record(_ entry: HostExecAuditEntry) async
}

public actor InMemoryHostExecAuditSink: HostExecAuditSink {
    private var storage: [HostExecAuditEntry] = []

    public init() {}

    public func record(_ entry: HostExecAuditEntry) async {
        storage.append(entry)
    }

    public func entries() -> [HostExecAuditEntry] {
        storage
    }
}

public enum HostExecBrokerError: Error, Sendable, Equatable {
    case commandNotAllowlisted(command: String)
    case approvalRequired(command: String)
    case launchFailed(command: String, reason: String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
}

public actor HostExecBroker {
    private let allowlistedCommands: Set<String>
    private let auditSink: any HostExecAuditSink

    public init(
        allowlistedCommands: Set<String>,
        auditSink: any HostExecAuditSink
    ) {
        self.allowlistedCommands = allowlistedCommands
        self.auditSink = auditSink
    }

    public func run(_ request: HostExecRequest) async throws -> HostExecResult {
        let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isAllowlisted(command) else {
            await auditSink.record(
                HostExecAuditEntry(
                    requestID: request.requestID,
                    command: command,
                    arguments: request.arguments,
                    allowed: false,
                    reason: .notAllowlisted,
                    exitCode: nil
                )
            )
            throw HostExecBrokerError.commandNotAllowlisted(command: command)
        }

        guard request.hasExplicitApproval else {
            await auditSink.record(
                HostExecAuditEntry(
                    requestID: request.requestID,
                    command: command,
                    arguments: request.arguments,
                    allowed: false,
                    reason: .approvalRequired,
                    exitCode: nil
                )
            )
            throw HostExecBrokerError.approvalRequired(command: command)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = request.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            await auditSink.record(
                HostExecAuditEntry(
                    requestID: request.requestID,
                    command: command,
                    arguments: request.arguments,
                    allowed: false,
                    reason: .executionFailed,
                    exitCode: nil
                )
            )
            throw HostExecBrokerError.launchFailed(command: command, reason: error.localizedDescription)
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        let result = HostExecResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            durationMs: durationMs
        )

        if process.terminationStatus != 0 {
            await auditSink.record(
                HostExecAuditEntry(
                    requestID: request.requestID,
                    command: command,
                    arguments: request.arguments,
                    allowed: false,
                    reason: .executionFailed,
                    exitCode: process.terminationStatus
                )
            )
            throw HostExecBrokerError.commandFailed(
                command: command,
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }

        await auditSink.record(
            HostExecAuditEntry(
                requestID: request.requestID,
                command: command,
                arguments: request.arguments,
                allowed: true,
                reason: .executed,
                exitCode: process.terminationStatus
            )
        )

        return result
    }

    private func isAllowlisted(_ command: String) -> Bool {
        if allowlistedCommands.contains(command) {
            return true
        }
        let basename = URL(fileURLWithPath: command).lastPathComponent
        return allowlistedCommands.contains(basename)
    }
}
