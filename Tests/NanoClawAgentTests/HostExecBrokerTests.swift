import Foundation
import Testing
@testable import NanoClawAgent

@Test
func testHostExecBrokerDeniesNonAllowlistedCommand() async {
    let audit = InMemoryHostExecAuditSink()
    let broker = HostExecBroker(
        allowlistedCommands: ["echo"],
        auditSink: audit
    )

    do {
        _ = try await broker.run(
            HostExecRequest(
                command: "/usr/bin/true",
                arguments: [],
                hasExplicitApproval: true,
                requestID: "req-1"
            )
        )
        Issue.record("Expected broker to deny non-allowlisted command")
    } catch let error as HostExecBrokerError {
        #expect(error == .commandNotAllowlisted(command: "/usr/bin/true"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    let entries = await audit.entries()
    #expect(entries.count == 1)
    #expect(entries[0].requestID == "req-1")
    #expect(entries[0].allowed == false)
    #expect(entries[0].reason == .notAllowlisted)
}

@Test
func testHostExecBrokerRequiresApprovalForAllowlistedCommand() async {
    let audit = InMemoryHostExecAuditSink()
    let broker = HostExecBroker(
        allowlistedCommands: ["echo"],
        auditSink: audit
    )

    do {
        _ = try await broker.run(
            HostExecRequest(
                command: "/bin/echo",
                arguments: ["hello"],
                hasExplicitApproval: false,
                requestID: "req-2"
            )
        )
        Issue.record("Expected broker to require explicit approval")
    } catch let error as HostExecBrokerError {
        #expect(error == .approvalRequired(command: "/bin/echo"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    let entries = await audit.entries()
    #expect(entries.count == 1)
    #expect(entries[0].requestID == "req-2")
    #expect(entries[0].allowed == false)
    #expect(entries[0].reason == .approvalRequired)
}

@Test
func testHostExecBrokerExecutesAllowlistedApprovedCommandAndAudits() async throws {
    let audit = InMemoryHostExecAuditSink()
    let broker = HostExecBroker(
        allowlistedCommands: ["echo"],
        auditSink: audit
    )

    let result = try await broker.run(
        HostExecRequest(
            command: "/bin/echo",
            arguments: ["hello"],
            hasExplicitApproval: true,
            requestID: "req-3"
        )
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello"))

    let entries = await audit.entries()
    #expect(entries.count == 1)
    #expect(entries[0].requestID == "req-3")
    #expect(entries[0].allowed == true)
    #expect(entries[0].reason == .executed)
    #expect(entries[0].exitCode == 0)
}

@Test
func testHostExecBrokerAuditsNonZeroExitAsExecutionFailure() async {
    let audit = InMemoryHostExecAuditSink()
    let broker = HostExecBroker(
        allowlistedCommands: ["false"],
        auditSink: audit
    )

    do {
        _ = try await broker.run(
            HostExecRequest(
                command: "/usr/bin/false",
                arguments: [],
                hasExplicitApproval: true,
                requestID: "req-4"
            )
        )
        Issue.record("Expected non-zero command to fail")
    } catch let error as HostExecBrokerError {
        guard case .commandFailed(let command, let exitCode, let stderr) = error else {
            Issue.record("Unexpected host exec error case: \(error)")
            return
        }
        #expect(command == "/usr/bin/false")
        #expect(exitCode != 0)
        #expect(stderr.isEmpty)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    let entries = await audit.entries()
    #expect(entries.count == 1)
    #expect(entries[0].requestID == "req-4")
    #expect(entries[0].allowed == false)
    #expect(entries[0].reason == .executionFailed)
    #expect(entries[0].exitCode == 1)
}
