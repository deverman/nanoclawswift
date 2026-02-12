import ArgumentParser
import Dispatch
import Foundation
import Logging

struct NanoClawHostCLI: ParsableCommand {
    @Option(name: [.long], help: "Unix socket path for host API")
    var socketPath: String = "/tmp/nanoclaw-host.sock"

    @Option(name: [.long], help: "Project root directory")
    var projectRoot: String = FileManager.default.currentDirectoryPath

    @Option(name: [.long], help: "Groups directory")
    var groupsDir: String?

    @Option(name: [.long], help: "Data directory")
    var dataDir: String?

    @Option(name: [.long], help: "Store directory")
    var storeDir: String?

    @Option(name: [.long], help: "Container image tag")
    var containerImage: String = ProcessInfo.processInfo.environment["CONTAINER_IMAGE"] ?? "nanoclawswift-agent:slim"

    @Option(name: [.long], help: "Container timeout (milliseconds)")
    var containerTimeoutMs: Int = Int(ProcessInfo.processInfo.environment["CONTAINER_TIMEOUT"] ?? "300000") ?? 300000

    @Option(name: [.long], help: "Container poll interval while waiting for IPC response (milliseconds)")
    var containerPollMs: Int = 120

    @Option(name: [.long], help: "Max concurrently active group workers")
    var maxConcurrentGroups: Int = Int(ProcessInfo.processInfo.environment["NANOCLAW_MAX_CONCURRENCY"] ?? "2") ?? 2

    mutating func run() throws {
        let options = ParsedHostOptions(
            socketPath: socketPath,
            projectRoot: projectRoot,
            groupsDir: groupsDir,
            dataDir: dataDir,
            storeDir: storeDir,
            containerImage: containerImage,
            containerTimeoutMs: containerTimeoutMs,
            containerPollMs: containerPollMs,
            maxConcurrentGroups: maxConcurrentGroups
        )

        let semaphore = DispatchSemaphore(value: 0)
        var runError: Error?
        Task {
            do {
                try await runHost(options: options)
            } catch {
                runError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let runError {
            throw runError
        }
    }
}

private struct ParsedHostOptions {
    let socketPath: String
    let projectRoot: String
    let groupsDir: String?
    let dataDir: String?
    let storeDir: String?
    let containerImage: String
    let containerTimeoutMs: Int
    let containerPollMs: Int
    let maxConcurrentGroups: Int
}

private func runHost(options: ParsedHostOptions) async throws {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            if let level = ProcessInfo.processInfo.environment["NANOCLAW_LOG_LEVEL"],
               let parsed = Logger.Level(rawValue: level.lowercased()) {
                handler.logLevel = parsed
            } else {
                handler.logLevel = .info
            }
            return handler
        }
        let logger = Logger(label: "nanoclaw.host")

        let groups = options.groupsDir ?? URL(fileURLWithPath: options.projectRoot).appendingPathComponent("groups").path
        let data = options.dataDir ?? URL(fileURLWithPath: options.projectRoot).appendingPathComponent("data").path
        let store = options.storeDir ?? URL(fileURLWithPath: options.projectRoot).appendingPathComponent("store").path
        let dbPath = URL(fileURLWithPath: store).appendingPathComponent("messages.db").path
        let assistantName = ProcessInfo.processInfo.environment["ASSISTANT_NAME"] ?? "Andy"

        let runtimeConfig = HostRuntimeConfig(
            projectRoot: options.projectRoot,
            groupsDir: groups,
            storeDir: store,
            containerImage: options.containerImage,
            containerTimeoutMs: options.containerTimeoutMs,
            containerPollMs: options.containerPollMs
        )

        let service = try NanoClawHostService(
            logger: logger,
            assistantName: assistantName,
            runtimeConfig: runtimeConfig,
            dataDir: data,
            databasePath: dbPath,
            maxConcurrentGroups: options.maxConcurrentGroups
        )

        await service.start()

        let server = UnixHTTPServer(socketPath: options.socketPath, logger: logger) { request in
            await service.handleRequest(request)
        }
        try server.start()

        logger.info("NanoClawHost running. socket=\(options.socketPath)")

        let signalSourceINT = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let signalSourceTERM = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let done = AsyncStream<Void> { continuation in
            signalSourceINT.setEventHandler {
                continuation.yield(())
                continuation.finish()
            }
            signalSourceTERM.setEventHandler {
                continuation.yield(())
                continuation.finish()
            }
            signalSourceINT.resume()
            signalSourceTERM.resume()
        }

        for await _ in done {
            break
        }

        logger.info("NanoClawHost shutting down")
        server.stop()
        await service.shutdown()
}

NanoClawHostCLI.main()
