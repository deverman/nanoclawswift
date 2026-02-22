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
    var containerImage: String?

    @Option(name: [.long], help: "Container timeout (milliseconds)")
    var containerTimeoutMs: Int?

    @Option(name: [.long], help: "Container poll interval while waiting for IPC response (milliseconds)")
    var containerPollMs: Int = 120

    @Option(name: [.long], help: "Max concurrently active group workers")
    var maxConcurrentGroups: Int?

    mutating func run() throws {
        let hostEnvironment = HostEnvironmentConfig.load()
        let options = ParsedHostOptions(
            socketPath: socketPath,
            projectRoot: projectRoot,
            groupsDir: groupsDir,
            dataDir: dataDir,
            storeDir: storeDir,
            containerImage: containerImage ?? hostEnvironment.containerImage,
            containerTimeoutMs: containerTimeoutMs ?? hostEnvironment.containerTimeoutMs,
            containerPollMs: containerPollMs,
            maxConcurrentGroups: maxConcurrentGroups ?? hostEnvironment.maxConcurrentGroups
        )

        let semaphore = DispatchSemaphore(value: 0)
        var runError: Error?
        Task {
            do {
                try await runHost(options: options, hostEnvironment: hostEnvironment)
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

private func runHost(options: ParsedHostOptions, hostEnvironment: HostEnvironmentConfig) async throws {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            if let logLevel = hostEnvironment.logLevel {
                handler.logLevel = logLevel
            } else {
                handler.logLevel = .info
            }
            return handler
        }
        let logger = Logger(label: "nanoclaw.host")

        let stateRoot = defaultStateRootPath()
        let groups = options.groupsDir ?? URL(fileURLWithPath: stateRoot).appendingPathComponent("groups").path
        let data = options.dataDir ?? URL(fileURLWithPath: stateRoot).appendingPathComponent("data").path
        let store = options.storeDir ?? URL(fileURLWithPath: stateRoot).appendingPathComponent("store").path
        let dbPath = URL(fileURLWithPath: store).appendingPathComponent("messages.db").path
        try FileManager.default.createDirectory(atPath: groups, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true)
        let assistantName = hostEnvironment.assistantName
        let telegramBotToken = hostEnvironment.telegramBotToken
        let telegramOwnerIDRaw = hostEnvironment.telegramOwnerIDRaw
        let telegramOwnerID = hostEnvironment.telegramOwnerID
        if hostEnvironment.hasInvalidTelegramOwnerID {
            logger.warning("Ignoring invalid TELEGRAM_OWNER_ID value: \(telegramOwnerIDRaw)")
        }
        let telegramPollLimit = hostEnvironment.telegramPollLimit
        let telegramPollTimeoutSec = hostEnvironment.telegramPollTimeoutSec
        let relaySettings = LLMRelaySettings(
            mode: hostEnvironment.llmRelayMode,
            bindHost: hostEnvironment.llmRelayBindHost,
            advertiseHost: hostEnvironment.llmRelayAdvertiseHost,
            port: hostEnvironment.llmRelayPort
        )

        var llmRelayServer: LLMRelayServer?
        if relaySettings.mode != .off {
            let relay = LLMRelayServer(
                settings: relaySettings,
                logger: logger,
                focusRelayEnabled: hostEnvironment.focusRelayEnabled,
                focusRelayCommand: hostEnvironment.focusRelayCommand
            )
            do {
                try relay.start()
                llmRelayServer = relay
            } catch {
                logger.warning("Swift LLM relay failed to start: \(error.localizedDescription)")
            }
        }

        let telegramTransport: (any TelegramTransport)?
        let inboundMediaPipeline: TelegramInboundMediaPipeline?
        if telegramBotToken.isEmpty {
            logger.info("TELEGRAM_BOT_TOKEN not set; Swift Telegram inbound/outbound disabled")
            telegramTransport = nil
            inboundMediaPipeline = nil
        } else {
            telegramTransport = TelegramBotAPITransport(
                botToken: telegramBotToken,
                logger: logger
            )
            #if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
            let imageTextExtractor: any ImageTextExtracting = VisionImageTextExtractor()
            #else
            let imageTextExtractor: any ImageTextExtracting = NoopImageTextExtractor()
            #endif
            inboundMediaPipeline = TelegramInboundMediaPipeline(
                groupsDir: groups,
                logger: logger,
                fetcher: TelegramBotFileFetcher(botToken: telegramBotToken),
                extractor: imageTextExtractor
            )
        }

        var containerPassthrough = LLMRelayConfig.applyRelayBaseURLIfNeeded(
            passthrough: hostEnvironment.containerPassthroughEnvironment,
            settings: relaySettings
        )
        if relaySettings.mode != .off,
           containerPassthrough["NANOCLAW_FOCUSRELAY_BROKER_URL"]?.isEmpty ?? true {
            containerPassthrough["NANOCLAW_FOCUSRELAY_BROKER_URL"] = "\(relaySettings.relayBaseRoot)/focusrelay"
        }
        if relaySettings.mode != .off,
           containerPassthrough["NANOCLAW_MCP_HOST_BROKER_URL"]?.isEmpty ?? true {
            containerPassthrough["NANOCLAW_MCP_HOST_BROKER_URL"] = "\(relaySettings.relayBaseRoot)/mcp/host"
        }
        let runtimeConfig = HostRuntimeConfig(
            projectRoot: options.projectRoot,
            groupsDir: groups,
            storeDir: store,
            containerImage: options.containerImage,
            containerTimeoutMs: options.containerTimeoutMs,
            containerPollMs: options.containerPollMs,
            queueJobWatchdogMs: hostEnvironment.queueJobWatchdogMs,
            sessionJanitorIntervalSec: hostEnvironment.sessionJanitorIntervalSec,
            staleClaimReapAgeSec: hostEnvironment.staleClaimReapAgeSec,
            containerPassthroughEnvironment: containerPassthrough
        )

        let service = try NanoClawHostService(
            logger: logger,
            assistantName: assistantName,
            hostEnvironment: hostEnvironment,
            runtimeConfig: runtimeConfig,
            dataDir: data,
            databasePath: dbPath,
            maxConcurrentGroups: options.maxConcurrentGroups,
            telegramTransport: telegramTransport,
            inboundMediaPipeline: inboundMediaPipeline
        )

        let telegramInboundAdapter: SwiftTelegramPollingAdapter?
        if telegramBotToken.isEmpty {
            telegramInboundAdapter = nil
        } else {
            telegramInboundAdapter = try await SwiftTelegramPollingAdapter(
                config: .init(
                    botToken: telegramBotToken,
                    assistantName: assistantName,
                    ownerID: telegramOwnerID,
                    pollLimit: max(1, min(telegramPollLimit, 100)),
                    pollTimeoutSec: max(1, min(telegramPollTimeoutSec, 50))
                ),
                logger: logger
            ) { event in
                _ = await service.ingestInboundEvent(event)
            }
        }

        await service.start()
        try await telegramInboundAdapter?.start()

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
        llmRelayServer?.stop()
        await telegramInboundAdapter?.stop()
        await service.shutdown()
}

private func defaultStateRootPath() -> String {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config")
        .appendingPathComponent("clawclaw")
        .path
}

NanoClawHostCLI.main()
