import Foundation
import Logging
import CronEngineKit
import NanoClawCommandKit

actor NanoClawHostService {
    struct IPCMessageCommand: Equatable {
        let channel: String
        let chatJID: String
        let text: String
        let kind: String
        let attachmentPath: String?
        let caption: String?
    }

    struct IPCProcessingOutcome: Equatable {
        var outboundMessagesFromIPC: Int = 0
    }

    private let logger: Logger
    private let assistantName: String
    private let store: SQLiteStore
    private let sessionManager: ContainerSessionManager
    private let runtimeConfig: HostRuntimeConfig
    private let maxConcurrentGroups: Int
    private let cronEngine: any CronEngine
    private let schedulerTimeZone: TimeZone
    private let prewarmEnabled: Bool
    private let prewarmLimit: Int
    private let workingAckEnabled: Bool
    private let workingAckThresholdMs: Int
    private let workingAckRepeatIntervalMs: Int
    private let workingAckMaxUpdates: Int
    private let latencyWindowSize: Int
    private let latencySLOP50Ms: Int
    private let latencySLOP95Ms: Int
    private let timeoutAlertRate: Double
    private let retryAlertRate: Double
    private let scheduledNewsFreshnessWindowDays: Int
    private let scheduledRetryMaxAttempts: Int
    private let scheduledRetryInitialBackoffSec: Int
    private let scheduledRetryMaxBackoffSec: Int
    private let ownerDirectChatJID: String?
    private let telegramOutboundCoordinator: SwiftTelegramOutboundCoordinator?
    private let telegramTypingHeartbeat: TelegramTypingHeartbeat?
    private let inboundMediaPipeline: TelegramInboundMediaPipeline?
    private let telegramOutboundPollMs: Int
    private let telegramOutboundBatchSize: Int
    private let isoFormatter = ISO8601DateFormatter()
    private var schedulerTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var telegramOutboundTask: Task<Void, Never>?
    private var janitorTask: Task<Void, Never>?
    private var shuttingDown = false
    private var runningScheduledTaskIDs: Set<String> = []
    private var workingAckTasks: [String: Task<Void, Never>] = [:]
    private var totalInboundEvents = 0
    private var duplicateInboundEvents = 0
    private var completedJobs = 0
    private var timeoutJobs = 0
    private var latencySamplesMs: [Int] = []
    private var scheduledRetryAttempts: [String: Int] = [:]

    private lazy var queue: GroupQueue = GroupQueue(
        maxConcurrentGroups: maxConcurrentGroups,
        logger: logger
    ) { [weak self] job in
        await self?.process(job: job)
    }

    init(
        logger: Logger,
        assistantName: String,
        hostEnvironment: HostEnvironmentConfig,
        runtimeConfig: HostRuntimeConfig,
        dataDir: String,
        databasePath: String,
        maxConcurrentGroups: Int,
        telegramTransport: (any TelegramTransport)? = nil,
        inboundMediaPipeline: TelegramInboundMediaPipeline? = nil
    ) throws {
        self.logger = logger
        self.assistantName = assistantName
        self.runtimeConfig = runtimeConfig
        self.maxConcurrentGroups = maxConcurrentGroups
        self.inboundMediaPipeline = inboundMediaPipeline
        self.store = try SQLiteStore(dbPath: databasePath, dataDir: dataDir, logger: logger)
        self.sessionManager = ContainerSessionManager(config: runtimeConfig, logger: logger)
        self.cronEngine = VixieCronEngine()
        self.prewarmEnabled = hostEnvironment.prewarmEnabled
        self.prewarmLimit = max(
            0,
            hostEnvironment.prewarmLimit
        )
        self.workingAckEnabled = hostEnvironment.workingAckEnabled
        self.workingAckThresholdMs = max(
            1000,
            hostEnvironment.workingAckThresholdMs
        )
        self.workingAckRepeatIntervalMs = max(
            5000,
            hostEnvironment.workingAckRepeatIntervalMs
        )
        self.workingAckMaxUpdates = max(
            1,
            hostEnvironment.workingAckMaxUpdates
        )
        self.latencyWindowSize = max(
            20,
            hostEnvironment.latencyWindowSize
        )
        let parsedP50 = max(
            1000,
            hostEnvironment.latencySLOP50Ms
        )
        self.latencySLOP50Ms = parsedP50
        self.latencySLOP95Ms = max(
            parsedP50,
            hostEnvironment.latencySLOP95Ms
        )
        self.timeoutAlertRate = hostEnvironment.timeoutAlertRate
        self.retryAlertRate = hostEnvironment.retryAlertRate
        self.scheduledNewsFreshnessWindowDays = max(1, hostEnvironment.scheduledNewsFreshnessWindowDays)
        self.scheduledRetryMaxAttempts = max(0, hostEnvironment.scheduledRetryMaxAttempts)
        self.scheduledRetryInitialBackoffSec = max(1, hostEnvironment.scheduledRetryInitialBackoffSec)
        self.scheduledRetryMaxBackoffSec = max(
            self.scheduledRetryInitialBackoffSec,
            hostEnvironment.scheduledRetryMaxBackoffSec
        )
        self.ownerDirectChatJID = Self.ownerDirectChatJID(ownerID: hostEnvironment.telegramOwnerID)
        self.telegramOutboundPollMs = max(200, hostEnvironment.telegramOutboundPollMs)
        self.telegramOutboundBatchSize = max(1, min(hostEnvironment.telegramOutboundBatchSize, 50))
        let typingIntervalMs = hostEnvironment.telegramTypingIntervalMs
        let typingDelayMs = hostEnvironment.telegramTypingStartDelayMs
        if let telegramTransport {
            self.telegramOutboundCoordinator = SwiftTelegramOutboundCoordinator(
                store: self.store,
                transport: telegramTransport,
                logger: logger,
                retryPolicy: TelegramDeliveryRetrier(
                    maxAttempts: 3,
                    initialBackoffMs: 250,
                    maxBackoffMs: 2_000
                )
            )
            self.telegramTypingHeartbeat = TelegramTypingHeartbeat(
                transport: telegramTransport,
                logger: logger,
                retryPolicy: TelegramDeliveryRetrier(
                    maxAttempts: 2,
                    initialBackoffMs: 250,
                    maxBackoffMs: 1_000
                ),
                intervalMs: typingIntervalMs,
                initialDelayMs: typingDelayMs
            )
        } else {
            self.telegramOutboundCoordinator = nil
            self.telegramTypingHeartbeat = nil
        }
        self.schedulerTimeZone = hostEnvironment.schedulerTimeZone
    }

    func start() async {
        await sessionManager.sweepStaleContainers()
        await enqueueDueScheduledTasks(reason: "startup")
        schedulerTask = Task { [weak self] in
            await self?.schedulerLoop()
        }
        if prewarmEnabled, prewarmLimit > 0 {
            prewarmTask = Task { [weak self] in
                await self?.prewarmGroupSessions()
            }
        }
        if let telegramOutboundCoordinator {
            let pollMs = telegramOutboundPollMs
            let batchSize = telegramOutboundBatchSize
            telegramOutboundTask = Task { [logger] in
                logger.info(
                    "Swift Telegram outbound loop started pollMs=\(pollMs) maxBatch=\(batchSize)"
                )
                await telegramOutboundCoordinator.runPollingLoop(
                    pollIntervalMs: pollMs,
                    maxCount: batchSize
                )
                logger.info("Swift Telegram outbound loop stopped")
            }
        }
        janitorTask = Task { [weak self] in
            await self?.janitorLoop()
        }
    }

    func shutdown() async {
        shuttingDown = true
        schedulerTask?.cancel()
        schedulerTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        telegramOutboundTask?.cancel()
        telegramOutboundTask = nil
        janitorTask?.cancel()
        janitorTask = nil
        for task in workingAckTasks.values {
            task.cancel()
        }
        workingAckTasks.removeAll()
        await sessionManager.stopAllSessions()
    }

    func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            switch (request.method, request.path) {
            case ("POST", "/v1/events/inbound"):
                let payload = try JSONDecoder().decode(InboundEventRequest.self, from: request.body)
                let response = try await handleInbound(payload)
                return .json(response, statusCode: response.accepted ? 202 : 200)

            case ("POST", "/v1/outbound/claim"):
                let payload = try JSONDecoder().decode(OutboundClaimRequest.self, from: request.body)
                let response = try await handleOutboundClaim(payload)
                return .json(response)

            case ("POST", "/v1/outbound/ack"):
                let payload = try JSONDecoder().decode(OutboundAckRequest.self, from: request.body)
                let response = try await handleOutboundAck(payload)
                return .json(response)

            case ("GET", "/v1/health"):
                let response = await health()
                return .json(response)

            case ("POST", "/v1/health"):
                let response = await health()
                return .json(response)

            default:
                return .json(["error": "Not found"], statusCode: 404)
            }
        } catch {
            logger.error("Host request handling error: \(error.localizedDescription)")
            return .json(["error": error.localizedDescription], statusCode: 400)
        }
    }

    func ingestInboundEvent(_ event: InboundEventRequest) async -> InboundEventResponse {
        do {
            return try await handleInbound(event)
        } catch {
            logger.error("Inbound ingestion failed: \(error.localizedDescription)")
            return InboundEventResponse(
                accepted: false,
                group_folder: nil,
                request_id: nil
            )
        }
    }

    private func handleInbound(_ event: InboundEventRequest) async throws -> InboundEventResponse {
        guard !shuttingDown else {
            return InboundEventResponse(accepted: false, group_folder: nil, request_id: nil)
        }
        totalInboundEvents += 1

        let isNewMessage = try store.tryInsertInboundEvent(
            channel: event.channel,
            chatJID: event.chat_jid,
            messageID: event.message_id
        )
        if !isNewMessage {
            duplicateInboundEvents += 1
            logger.info("Ignoring duplicate inbound event: \(event.channel) \(event.chat_jid) \(event.message_id)")
            return InboundEventResponse(accepted: false, group_folder: nil, request_id: nil)
        }

        guard let group = try await resolveGroup(for: event) else {
            logger.warning("Inbound event ignored (group not registered): \(event.chat_jid)")
            return InboundEventResponse(accepted: false, group_folder: nil, request_id: nil)
        }

        let enrichedEvent: InboundEventRequest
        if let inboundMediaPipeline {
            enrichedEvent = await inboundMediaPipeline.enrich(event: event, groupFolder: group.folder)
        } else {
            enrichedEvent = event
        }

        if let commandResponse = try handleTelegramDirectCommandIfNeeded(event: enrichedEvent, group: group) {
            return commandResponse
        }

        let requestID = "req-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
        let enqueuedAt = Date()
        let job = QueueJob(
            requestID: requestID,
            channel: event.channel,
            chatJID: enrichedEvent.chat_jid,
            sender: enrichedEvent.sender,
            senderName: enrichedEvent.sender_name,
            content: enrichedEvent.content,
            timestamp: enrichedEvent.timestamp,
            messageID: enrichedEvent.message_id,
            group: group,
            isScheduledTask: false,
            isStartupCatchUp: false,
            scheduledTaskID: nil,
            contextMode: "group",
            enqueuedAt: enqueuedAt
        )

        await queue.enqueue(job)
        scheduleWorkingAck(for: job)
        let queueDepth = await queue.queueDepth()
        logger.info(
            "Accepted inbound event \(event.channel) \(event.chat_jid) request=\(requestID) group=\(group.folder) queueDepth=\(queueDepth)"
        )

        return InboundEventResponse(
            accepted: true,
            group_folder: group.folder,
            request_id: requestID
        )
    }

    private func handleOutboundClaim(_ request: OutboundClaimRequest) async throws -> OutboundClaimResponse {
        let rows = try store.claimOutbound(
            channel: request.channel,
            maxCount: request.max_count ?? 10
        )
        return OutboundClaimResponse(
            messages: rows.map {
                OutboundMessageDTO(
                    id: $0.id,
                    chat_jid: $0.chatJID,
                    text: $0.text,
                    kind: $0.kind,
                    attachment_path: $0.attachmentPath,
                    caption: $0.caption,
                    created_at: $0.createdAt
                )
            }
        )
    }

    private func handleOutboundAck(_ request: OutboundAckRequest) async throws -> OutboundAckResponse {
        let ackedCount = try store.ackOutbound(messageIDs: request.message_ids)
        return OutboundAckResponse(acked_count: ackedCount)
    }

    private func health() async -> HealthResponse {
        let dbStatus = store.isHealthy() ? "ok" : "error"
        let queueDepth = await queue.queueDepth()
        let activeSessions = await sessionManager.activeSessionCount()
        let latency = latencySummary()
        return HealthResponse(
            ok: dbStatus == "ok",
            active_group_sessions: activeSessions,
            queue_depth: queueDepth,
            db_status: dbStatus,
            response_p50_ms: latency.p50,
            response_p95_ms: latency.p95,
            timeout_rate: latency.timeoutRate,
            retry_rate: latency.retryRate,
            completed_jobs: latency.sampleCount
        )
    }

    private func resolveGroup(for event: InboundEventRequest) async throws -> RegisteredGroupRow? {
        if let existing = try store.fetchGroup(jid: event.chat_jid) {
            return existing
        }

        if event.channel == "telegram", event.is_direct {
            let group = RegisteredGroupRow(
                jid: event.chat_jid,
                name: "Telegram Direct (\(event.sender_name))",
                folder: "telegram-direct",
                triggerPattern: "@\(assistantName)",
                addedAt: isoNow(),
                containerConfigJSON: nil,
                requiresTrigger: false
            )
            try store.upsertGroup(group)
            return group
        }

        return nil
    }

    private func process(job: QueueJob) async {
        defer { cancelWorkingAck(requestID: job.requestID) }
        let startedAt = Date()
        let queueWaitMs = max(0, Int(startedAt.timeIntervalSince(job.enqueuedAt) * 1000))
        var snapshotMs: Int?
        var sessionLoadMs: Int?
        var containerMs: Int?
        var ipcMs: Int?
        var outboundMs: Int?
        var sessionPersistMs: Int?
        var toolCallsCount: Int?
        var agentDurationMs: Int?

        func elapsedMs(since date: Date) -> Int {
            max(0, Int(Date().timeIntervalSince(date) * 1000))
        }

        logger.info(
            "Processing queue job request=\(job.requestID) group=\(job.group.folder) scheduled=\(job.isScheduledTask) queueWaitMs=\(queueWaitMs)"
        )

        do {
            if job.isScheduledTask, job.isStartupCatchUp {
                let notice = Self.startupCatchUpNotice(
                    taskID: job.scheduledTaskID,
                    prompt: job.content
                )
                _ = try store.enqueueOutbound(
                    channel: job.channel,
                    chatJID: job.chatJID,
                    text: notice
                )
            }

            if Self.requiresPreRunTaskSnapshot(for: job.content) {
                let snapshotStart = Date()
                try await writeTaskSnapshot(for: job.group)
                snapshotMs = elapsedMs(since: snapshotStart)
            } else {
                snapshotMs = 0
            }

            let sessionLoadStart = Date()
            let session: SessionRow?
            if job.contextMode == "isolated" {
                session = nil
            } else {
                session = try store.getSession(scopeKey: job.group.folder)
            }
            sessionLoadMs = elapsedMs(since: sessionLoadStart)

            let payload = ContainerRequestPayload(
                request_id: job.requestID,
                prompt: job.content,
                session_id: session?.sessionID,
                chat_jid: job.chatJID,
                group_folder: job.group.folder,
                is_main: job.group.folder == "main",
                is_scheduled_task: job.isScheduledTask
            )
            let containerStart = Date()
            let response: ContainerResponsePayload
            if job.channel == "telegram",
               !job.isScheduledTask,
               let telegramTypingHeartbeat {
                let typingTask = telegramTypingHeartbeat.start(chatJID: job.chatJID)
                defer { typingTask.cancel() }
                response = try await runContainerRequestWithWatchdog(
                    group: job.group,
                    payload: payload
                )
            } else {
                response = try await runContainerRequestWithWatchdog(
                    group: job.group,
                    payload: payload
                )
            }
            containerMs = elapsedMs(since: containerStart)
            toolCallsCount = response.tool_calls_count
            agentDurationMs = response.duration_ms

            var normalizedResponse = response
            let rawResult = response.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let responseToolCalls = response.tool_calls_count ?? 0
            if response.status == "success",
               !rawResult.isEmpty,
               responseToolCalls == 0,
               Self.containsPseudoToolOutput(rawResult) {
                logger.warning(
                    "Run returned pseudo tool output; coercing to error request=\(job.requestID) scheduled=\(job.isScheduledTask)"
                )
                normalizedResponse = ContainerResponsePayload(
                    request_id: response.request_id,
                    status: "error",
                    result: nil,
                    new_session_id: response.new_session_id,
                    error: "Model returned pseudo tool syntax without structured tool calls.",
                    tool_calls_count: response.tool_calls_count,
                    duration_ms: response.duration_ms
                )
            }

            let sessionPersistStart = Date()
            if let newSessionID = normalizedResponse.new_session_id, !newSessionID.isEmpty {
                try store.upsertSession(scopeKey: job.group.folder, sessionID: newSessionID)
            }
            sessionPersistMs = elapsedMs(since: sessionPersistStart)

            let ipcStart = Date()
            let ipcOutcome = try await processIpcArtifacts(sourceGroup: job.group)
            ipcMs = elapsedMs(since: ipcStart)

            if job.isScheduledTask {
                var scheduledResponse = normalizedResponse
                let originalPayload = payload
                let scheduledPrompt = job.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawScheduledResult = normalizedResponse.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if normalizedResponse.status == "success",
                   !rawScheduledResult.isEmpty,
                   Self.containsPseudoToolOutput(rawScheduledResult) {
                    logger.warning(
                        "Scheduled run returned pseudo tool output; coercing to error request=\(job.requestID) taskID=\(job.scheduledTaskID ?? "unknown")"
                    )
                    scheduledResponse = ContainerResponsePayload(
                        request_id: normalizedResponse.request_id,
                        status: "error",
                        result: nil,
                        new_session_id: normalizedResponse.new_session_id,
                        error: "Model returned pseudo tool syntax without structured tool calls.",
                        tool_calls_count: normalizedResponse.tool_calls_count,
                        duration_ms: normalizedResponse.duration_ms
                    )
                }
                let scheduledToolCalls = scheduledResponse.tool_calls_count ?? 0
                if scheduledResponse.status == "success",
                   scheduledToolCalls == 0,
                   Self.scheduledPromptRequiresToolExecution(scheduledPrompt) {
                    logger.warning(
                        "Scheduled run required tool execution but returned zero tool calls; coercing to error request=\(job.requestID) taskID=\(job.scheduledTaskID ?? "unknown")"
                    )
                    scheduledResponse = ContainerResponsePayload(
                        request_id: scheduledResponse.request_id,
                        status: "error",
                        result: nil,
                        new_session_id: scheduledResponse.new_session_id,
                        error: "Scheduled run required tool execution, but the model returned no structured tool calls.",
                        tool_calls_count: scheduledResponse.tool_calls_count,
                        duration_ms: scheduledResponse.duration_ms
                    )
                }
                if scheduledResponse.status == "success",
                   let freshnessFailure = Self.scheduledNewsFreshnessFailure(
                       prompt: scheduledPrompt,
                       result: scheduledResponse.result,
                       freshnessWindowDays: scheduledNewsFreshnessWindowDays,
                       now: Date()
                   ) {
                    logger.warning(
                        "Scheduled run failed freshness gate request=\(job.requestID) taskID=\(job.scheduledTaskID ?? "unknown") reason=\(freshnessFailure)"
                    )
                    scheduledResponse = ContainerResponsePayload(
                        request_id: scheduledResponse.request_id,
                        status: "error",
                        result: nil,
                        new_session_id: scheduledResponse.new_session_id,
                        error: freshnessFailure,
                        tool_calls_count: scheduledResponse.tool_calls_count,
                        duration_ms: scheduledResponse.duration_ms
                    )
                }
                if Self.shouldAttemptScheduledToolRecovery(
                    prompt: scheduledPrompt,
                    response: scheduledResponse
                ) {
                    logger.warning(
                        "Scheduled run entering one-shot tool recovery request=\(job.requestID) taskID=\(job.scheduledTaskID ?? "unknown")"
                    )
                    let recoveryStart = Date()
                    let recoveryResponse = try await runContainerRequestWithWatchdog(
                        group: job.group,
                        payload: Self.scheduledToolRecoveryPayload(
                            from: originalPayload,
                            originalPrompt: scheduledPrompt
                        )
                    )
                    containerMs = (containerMs ?? 0) + elapsedMs(since: recoveryStart)
                    toolCallsCount = recoveryResponse.tool_calls_count
                    agentDurationMs = recoveryResponse.duration_ms
                    scheduledResponse = Self.normalizedScheduledRecoveryResponse(from: recoveryResponse)
                }
                let trimmedResult = scheduledResponse.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hasDirectResult = !trimmedResult.isEmpty
                let toolCalls = scheduledResponse.tool_calls_count ?? 0
                let shouldFallbackDirectResult =
                    scheduledResponse.status == "success"
                    && hasDirectResult
                    && (
                        ipcOutcome.outboundMessagesFromIPC == 0
                            || toolCalls == 0
                    )
                logger.info(
                    "Scheduled delivery decision request=\(job.requestID) status=\(scheduledResponse.status) hasDirectResult=\(hasDirectResult) ipcOutbound=\(ipcOutcome.outboundMessagesFromIPC) toolCalls=\(toolCalls) fallback=\(shouldFallbackDirectResult)"
                )
                if shouldFallbackDirectResult {
                    let chunks = splitAssistantOutboundText(
                        trimmedResult,
                        assistantName: assistantName,
                        for: job.channel
                    )
                    for chunk in chunks where !chunk.isEmpty {
                        _ = try store.enqueueOutbound(
                            channel: job.channel,
                            chatJID: job.chatJID,
                            text: chunk
                        )
                    }
                    logger.info(
                        "Scheduled run enqueued fallback direct result request=\(job.requestID) chat=\(job.chatJID)"
                    )
                }
                try await finalizeScheduledTask(job: job, response: scheduledResponse, startedAt: startedAt)
                let totalMs = elapsedMs(since: startedAt)
                let scheduledCause = ScheduledRunFailureClassifier.classify(
                    status: scheduledResponse.status,
                    detail: scheduledResponse.error
                )
                logger.info(
                    "Completed scheduled queue job request=\(job.requestID) group=\(job.group.folder) status=\(scheduledResponse.status) cause=\(scheduledCause?.rawValue ?? "none") transient=\(ScheduledRunFailureClassifier.isTransient(scheduledCause)) totalMs=\(totalMs) queueWaitMs=\(queueWaitMs) snapshotMs=\(snapshotMs ?? -1) sessionLoadMs=\(sessionLoadMs ?? -1) containerMs=\(containerMs ?? -1) sessionPersistMs=\(sessionPersistMs ?? -1) ipcMs=\(ipcMs ?? -1) toolCalls=\(toolCallsCount ?? -1) agentDurationMs=\(agentDurationMs ?? -1)"
                )
                return
            }

            let interactiveToolCalls = normalizedResponse.tool_calls_count ?? 0
            if normalizedResponse.status == "success",
               interactiveToolCalls == 0,
               Self.interactivePromptRequiresToolExecution(job.content) {
                logger.warning(
                    "Interactive run required tool execution but returned zero tool calls; coercing to error request=\(job.requestID) chat=\(job.chatJID)"
                )
                normalizedResponse = ContainerResponsePayload(
                    request_id: normalizedResponse.request_id,
                    status: "error",
                    result: nil,
                    new_session_id: normalizedResponse.new_session_id,
                    error: "This request requires live tool access (OmniFocus/MCP), but the model returned no structured tool calls. Please retry with /mcp-cli or ask me again and I will run the tool directly.",
                    tool_calls_count: normalizedResponse.tool_calls_count,
                    duration_ms: normalizedResponse.duration_ms
                )
            }

            let outboundStart = Date()
            if Self.shouldEnqueueDirectResult(
                status: normalizedResponse.status,
                result: normalizedResponse.result,
                ipcOutboundCount: ipcOutcome.outboundMessagesFromIPC
            ), let result = normalizedResponse.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                let chunks = splitAssistantOutboundText(
                    result,
                    assistantName: assistantName,
                    for: job.channel
                )
                for chunk in chunks where !chunk.isEmpty {
                    _ = try store.enqueueOutbound(
                        channel: job.channel,
                        chatJID: job.chatJID,
                        text: chunk
                    )
                }
            } else if normalizedResponse.status == "success",
                      ipcOutcome.outboundMessagesFromIPC > 0 {
                logger.info(
                    "Suppressed direct agent result because IPC outbound messages were emitted request=\(job.requestID) count=\(ipcOutcome.outboundMessagesFromIPC)"
                )
            } else if normalizedResponse.status == "success" {
                let fallback = "I finished processing your request, but I couldn’t produce a reply. Please try again."
                let chunks = splitAssistantOutboundText(
                    fallback,
                    assistantName: assistantName,
                    for: job.channel
                )
                for chunk in chunks where !chunk.isEmpty {
                    _ = try store.enqueueOutbound(
                        channel: job.channel,
                        chatJID: job.chatJID,
                        text: chunk
                    )
                }
            } else if let error = normalizedResponse.error {
                let chunks = splitAssistantOutboundText(
                    error,
                    assistantName: assistantName,
                    for: job.channel
                )
                for chunk in chunks where !chunk.isEmpty {
                    _ = try store.enqueueOutbound(
                        channel: job.channel,
                        chatJID: job.chatJID,
                        text: chunk
                    )
                }
            }
            outboundMs = elapsedMs(since: outboundStart)

            let totalMs = elapsedMs(since: startedAt)
            recordLatency(totalMs: totalMs, timedOut: isTimeoutLike(response.error))
            logger.info(
                "Completed queue job request=\(job.requestID) group=\(job.group.folder) status=\(normalizedResponse.status) totalMs=\(totalMs) queueWaitMs=\(queueWaitMs) snapshotMs=\(snapshotMs ?? -1) sessionLoadMs=\(sessionLoadMs ?? -1) containerMs=\(containerMs ?? -1) sessionPersistMs=\(sessionPersistMs ?? -1) ipcMs=\(ipcMs ?? -1) outboundMs=\(outboundMs ?? -1) toolCalls=\(toolCallsCount ?? -1) agentDurationMs=\(agentDurationMs ?? -1)"
            )
        } catch {
            let totalMs = elapsedMs(since: startedAt)
            if !job.isScheduledTask {
                recordLatency(totalMs: totalMs, timedOut: isTimeoutLike(error.localizedDescription))
            }
            logger.error(
                "Failed processing queue job request=\(job.requestID) group=\(job.group.folder) totalMs=\(totalMs) queueWaitMs=\(queueWaitMs) snapshotMs=\(snapshotMs ?? -1) sessionLoadMs=\(sessionLoadMs ?? -1) containerMs=\(containerMs ?? -1) sessionPersistMs=\(sessionPersistMs ?? -1) ipcMs=\(ipcMs ?? -1) outboundMs=\(outboundMs ?? -1) toolCalls=\(toolCallsCount ?? -1) agentDurationMs=\(agentDurationMs ?? -1) error=\(error.localizedDescription)"
            )
            if !job.isScheduledTask {
                let chunks = splitAssistantOutboundText(
                    "Error processing your request (\(error.localizedDescription))",
                    assistantName: assistantName,
                    for: job.channel
                )
                for chunk in chunks where !chunk.isEmpty {
                    _ = try? store.enqueueOutbound(
                        channel: job.channel,
                        chatJID: job.chatJID,
                        text: chunk
                    )
                }
            } else {
                let cause = ScheduledRunFailureClassifier.classify(
                    status: "error",
                    detail: error.localizedDescription
                )
                logger.error(
                    "Scheduled queue job failed request=\(job.requestID) taskID=\(job.scheduledTaskID ?? "unknown") group=\(job.group.folder) cause=\(cause?.rawValue ?? "unknown") transient=\(ScheduledRunFailureClassifier.isTransient(cause)) error=\(error.localizedDescription)"
                )
                if let taskID = job.scheduledTaskID,
                   let task = try? store.getTask(taskID: taskID) {
                    let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                    if let decision = retryDecision(taskID: task.id, cause: cause) {
                        let retryNextRun = isoNow(addingSeconds: decision.delaySec)
                        let retrySummary = "Transient failure (\(cause?.rawValue ?? "unknown")); retry \(decision.attempt)/\(scheduledRetryMaxAttempts) in \(decision.delaySec)s"
                        try? store.updateTaskAfterRun(taskID: task.id, nextRun: retryNextRun, resultSummary: retrySummary)
                        try? store.logTaskRun(
                            TaskRunLogRow(
                                taskID: task.id,
                                runAt: isoNow(),
                                durationMs: durationMs,
                                status: "error",
                                result: nil,
                                error: error.localizedDescription
                            )
                        )
                        logger.warning(
                            "Scheduled retry queued taskID=\(task.id) cause=\(cause?.rawValue ?? "unknown") attempt=\(decision.attempt)/\(scheduledRetryMaxAttempts) delaySec=\(decision.delaySec)"
                        )
                    } else {
                        clearScheduledRetryState(taskID: task.id)
                        let nextRun = nextRunISO(for: task)
                        let summary = "Error: \(error.localizedDescription.prefix(240))"
                        try? store.updateTaskAfterRun(taskID: task.id, nextRun: nextRun, resultSummary: summary)
                        try? store.logTaskRun(
                            TaskRunLogRow(
                                taskID: task.id,
                                runAt: isoNow(),
                                durationMs: durationMs,
                                status: "error",
                                result: nil,
                                error: error.localizedDescription
                            )
                        )
                        if let cause {
                            let notice = Self.scheduledFailureNotice(taskID: task.id, cause: cause)
                            let chunks = splitAssistantOutboundText(
                                notice,
                                assistantName: assistantName,
                                for: job.channel
                            )
                            for chunk in chunks where !chunk.isEmpty {
                                _ = try? store.enqueueOutbound(
                                    channel: job.channel,
                                    chatJID: job.chatJID,
                                    text: chunk
                                )
                            }
                        }
                    }
                }
                releaseScheduledTask(job.scheduledTaskID)
            }
        }
    }

    private func runContainerRequestWithWatchdog(
        group: RegisteredGroupRow,
        payload: ContainerRequestPayload
    ) async throws -> ContainerResponsePayload {
        let manager = sessionManager
        let containerTimeoutMs = runtimeConfig.containerTimeoutMs
        let requestedWatchdogMs = payload.is_scheduled_task
            ? runtimeConfig.scheduledQueueJobWatchdogMs
            : runtimeConfig.queueJobWatchdogMs
        let watchdogMs = Self.effectiveWatchdogMs(
            requestedWatchdogMs: requestedWatchdogMs,
            containerTimeoutMs: containerTimeoutMs
        )

        return try await withThrowingTaskGroup(of: ContainerResponsePayload.self) { groupTask in
            groupTask.addTask {
                try await manager.runRequest(
                    group: group,
                    payload: payload,
                    timeoutMs: containerTimeoutMs
                )
            }
            groupTask.addTask {
                try await Task.sleep(for: .milliseconds(watchdogMs))
                self.logger.error(
                    "Queue watchdog timed out request=\(payload.request_id) group=\(group.folder) watchdogMs=\(watchdogMs) containerTimeoutMs=\(containerTimeoutMs)"
                )
                Task {
                    await manager.recycleSession(for: group.folder)
                }
                throw ContainerSessionError.requestTimedOut(
                    message: "Queue watchdog timed out after \(watchdogMs)ms for request \(payload.request_id)"
                )
            }

            let first = try await groupTask.next()
            groupTask.cancelAll()
            if let first {
                return first
            }
            throw ContainerSessionError.requestFailed(
                message: "Queue watchdog failed to produce a container response for request \(payload.request_id)"
            )
        }
    }

    static func effectiveWatchdogMs(
        requestedWatchdogMs: Int,
        containerTimeoutMs: Int
    ) -> Int {
        let safeContainerTimeout = max(1000, containerTimeoutMs)
        let clampedRequested = max(1000, requestedWatchdogMs)
        let upperBound = max(1000, safeContainerTimeout - 1000)
        return min(clampedRequested, upperBound)
    }

    static func collapseLatestOutboundMessages(_ commands: [IPCMessageCommand]) -> [IPCMessageCommand] {
        guard commands.count > 1 else { return commands }
        var latestByChat: [String: IPCMessageCommand] = [:]
        var order: [String] = []
        for command in commands {
            if latestByChat[command.chatJID] == nil {
                order.append(command.chatJID)
            }
            latestByChat[command.chatJID] = command
        }
        return order.compactMap { latestByChat[$0] }
    }

    static func resolveAttachmentHostPath(
        containerPath: String,
        sourceGroupFolder: String,
        groupsDir: String
    ) -> String? {
        let trimmed = containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rootedPath: String = if trimmed.hasPrefix("/") {
            trimmed
        } else {
            "/workspace/group/\(trimmed)"
        }
        let normalizedContainerPath = URL(fileURLWithPath: rootedPath).standardized.path
        let root = "/workspace/group"
        guard normalizedContainerPath == root || normalizedContainerPath.hasPrefix("\(root)/") else {
            return nil
        }

        let suffix = String(normalizedContainerPath.dropFirst(root.count))
        let relativeSuffix = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
        let candidate = URL(fileURLWithPath: groupsDir)
            .appendingPathComponent(sourceGroupFolder)
            .appendingPathComponent(relativeSuffix)
            .standardized.path
        let allowedRoot = URL(fileURLWithPath: groupsDir)
            .appendingPathComponent(sourceGroupFolder)
            .standardized.path
        guard candidate == allowedRoot || candidate.hasPrefix("\(allowedRoot)/") else {
            return nil
        }
        return candidate
    }

    static func shouldEnqueueDirectResult(
        status: String,
        result: String?,
        ipcOutboundCount: Int
    ) -> Bool {
        guard status == "success",
              let trimmed = result?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        return ipcOutboundCount == 0
    }

    static func containsPseudoToolOutput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"`{3}\s*tool"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed.range(of: #"`{3}\s*functions?(?:\.[\w.-]+)?(?::\d+)?\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed.range(
            of: #"<\s*function[_-]?calls\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        if trimmed.range(
            of: #"<\s*invoke\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        return false
    }

    static func scheduledPromptRequiresToolExecution(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let reportMarkers = [
            "daily omnifocus priority report",
            "apple news digest",
            "swift programming tips",
            "report",
            "digest",
            "latest",
            "today",
            "news",
            "search",
            "query omni"
        ]
        return reportMarkers.contains(where: { normalized.contains($0) })
    }

    static func shouldAttemptScheduledToolRecovery(
        prompt: String,
        response: ContainerResponsePayload
    ) -> Bool {
        guard scheduledPromptRequiresToolExecution(prompt) else { return false }
        let cause = ScheduledRunFailureClassifier.classify(
            status: response.status,
            detail: response.error
        )
        switch cause {
        case .missingToolCalls, .toolError:
            return true
        default:
            return false
        }
    }

    static func scheduledToolRecoveryPayload(
        from payload: ContainerRequestPayload,
        originalPrompt: String
    ) -> ContainerRequestPayload {
        ContainerRequestPayload(
            request_id: payload.request_id + "-tool-recovery",
            prompt: scheduledToolRecoveryPrompt(from: originalPrompt),
            session_id: payload.session_id,
            chat_jid: payload.chat_jid,
            group_folder: payload.group_folder,
            is_main: payload.is_main,
            is_scheduled_task: payload.is_scheduled_task
        )
    }

    static func scheduledToolRecoveryPrompt(from originalPrompt: String) -> String {
        """
        \(originalPrompt)

        Critical execution requirement:
        - Use structured tool calls only for any live data, search, web, MCP, or OmniFocus access.
        - Do not describe tool calls, do not emit pseudo-tool syntax, and do not answer from memory.
        - If fresh live data cannot be retrieved, return a concise failure explaining which required tool call failed.
        """
    }

    static func normalizedScheduledRecoveryResponse(from response: ContainerResponsePayload) -> ContainerResponsePayload {
        let trimmedResult = response.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if response.status == "success",
           !trimmedResult.isEmpty,
           (response.tool_calls_count ?? 0) == 0,
           containsPseudoToolOutput(trimmedResult) {
            return ContainerResponsePayload(
                request_id: response.request_id,
                status: "error",
                result: nil,
                new_session_id: response.new_session_id,
                error: "Model returned pseudo tool syntax without structured tool calls.",
                tool_calls_count: response.tool_calls_count,
                duration_ms: response.duration_ms
            )
        }
        if response.status == "success",
           (response.tool_calls_count ?? 0) == 0 {
            return ContainerResponsePayload(
                request_id: response.request_id,
                status: "error",
                result: nil,
                new_session_id: response.new_session_id,
                error: "Scheduled run required tool execution, but the model returned no structured tool calls.",
                tool_calls_count: response.tool_calls_count,
                duration_ms: response.duration_ms
            )
        }
        return response
    }

    static func scheduledPromptRequiresFreshNewsSources(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let newsMarkers = [
            "news",
            "tip",
            "headline",
            "digest",
            "announcements",
            "launch",
            "latest updates",
            "what happened today",
            "nothing fresh",
            "published within the last"
        ]
        let domainMarkers = [
            "apple",
            "swift"
        ]
        return newsMarkers.contains { normalized.contains($0) }
            || (domainMarkers.contains { normalized.contains($0) } && normalized.contains("latest"))
    }

    static func scheduledNewsFreshnessFailure(
        prompt: String,
        result: String?,
        freshnessWindowDays: Int,
        now: Date
    ) -> String? {
        guard scheduledPromptRequiresFreshNewsSources(prompt) else { return nil }
        let safeWindowDays = max(1, freshnessWindowDays)
        let maxAllowedWindowDays = max(
            safeWindowDays,
            fallbackFreshnessWindowDays(from: prompt) ?? safeWindowDays
        )
        let trimmedResult = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedResult.isEmpty else {
            return "Scheduled news freshness check failed: empty report payload."
        }
        let dateReferences = extractDateReferencesForFreshnessCheck(from: trimmedResult)
        guard !dateReferences.isEmpty else {
            return "Scheduled news freshness check failed: missing dated sources in the report output."
        }
        let calendar = Calendar(identifier: .gregorian)
        let freshThreshold = calendar.date(byAdding: .day, value: -safeWindowDays, to: now) ?? now
        let maxAllowedThreshold = calendar.date(byAdding: .day, value: -maxAllowedWindowDays, to: now) ?? now
        let hasTooOldDate = dateReferences.contains { referencedDate in
            referencedDate < maxAllowedThreshold
        }
        if hasTooOldDate {
            return "Scheduled news freshness check failed: one or more cited source dates are older than \(maxAllowedWindowDays) days."
        }
        let hasFreshDate = dateReferences.contains { referencedDate in
            referencedDate >= freshThreshold
        }
        if hasFreshDate {
            return nil
        }
        if maxAllowedWindowDays > safeWindowDays {
            return nil
        }
        return "Scheduled news freshness check failed: all cited source dates are older than \(safeWindowDays) days."
    }

    static func fallbackFreshnessWindowDays(from prompt: String) -> Int? {
        let lower = prompt.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"last\s+(\d{1,3})\s+days"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        let matches = regex.matches(in: lower, options: [], range: nsRange)
        let values: [Int] = matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: lower) else { return nil }
            return Int(lower[range])
        }
        return values.max()
    }

    static func extractDateReferencesForFreshnessCheck(from text: String) -> [Date] {
        let sourceBody = sourceSectionBody(in: text) ?? text
        let patterns = [
            #"\b\d{4}-\d{2}-\d{2}\b"#,
            #"\b(?:jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\s+\d{1,2},\s+\d{4}\b"#,
            #"\b\d{1,2}\s+(?:jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\s+\d{4}\b"#
        ]
        var seen: Set<String> = []
        var dates: [Date] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(sourceBody.startIndex..<sourceBody.endIndex, in: sourceBody)
            let matches = regex.matches(in: sourceBody, options: [], range: nsRange)
            for match in matches {
                guard let range = Range(match.range, in: sourceBody) else { continue }
                let token = String(sourceBody[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { continue }
                let key = token.lowercased()
                guard !seen.contains(key) else { continue }
                guard let parsed = parseDateReference(token) else { continue }
                seen.insert(key)
                dates.append(parsed)
            }
        }
        return dates
    }

    static func sourceSectionBody(in text: String) -> String? {
        let lower = text.lowercased()
        guard let sourcesRange = lower.range(of: "sources") else { return nil }
        let suffix = String(text[sourcesRange.lowerBound...])
        let firstLineBreak = suffix.firstIndex(of: "\n") ?? suffix.startIndex
        if firstLineBreak == suffix.startIndex {
            return suffix
        }
        return String(suffix[firstLineBreak...])
    }

    static func parseDateReference(_ token: String) -> Date? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let isoFormatter = DateFormatter()
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        isoFormatter.dateFormat = "yyyy-MM-dd"
        if let parsed = isoFormatter.date(from: normalized) {
            return parsed
        }

        let monthDayYear = DateFormatter()
        monthDayYear.locale = Locale(identifier: "en_US_POSIX")
        monthDayYear.timeZone = TimeZone(secondsFromGMT: 0)
        monthDayYear.dateFormat = "MMMM d, yyyy"
        if let parsed = monthDayYear.date(from: normalized) {
            return parsed
        }

        let monthDayYearShort = DateFormatter()
        monthDayYearShort.locale = Locale(identifier: "en_US_POSIX")
        monthDayYearShort.timeZone = TimeZone(secondsFromGMT: 0)
        monthDayYearShort.dateFormat = "MMM d, yyyy"
        if let parsed = monthDayYearShort.date(from: normalized) {
            return parsed
        }

        let dayMonthYear = DateFormatter()
        dayMonthYear.locale = Locale(identifier: "en_US_POSIX")
        dayMonthYear.timeZone = TimeZone(secondsFromGMT: 0)
        dayMonthYear.dateFormat = "d MMMM yyyy"
        if let parsed = dayMonthYear.date(from: normalized) {
            return parsed
        }

        let dayMonthYearShort = DateFormatter()
        dayMonthYearShort.locale = Locale(identifier: "en_US_POSIX")
        dayMonthYearShort.timeZone = TimeZone(secondsFromGMT: 0)
        dayMonthYearShort.dateFormat = "d MMM yyyy"
        return dayMonthYearShort.date(from: normalized)
    }

    static func interactivePromptRequiresToolExecution(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let omniFocusMarkers = [
            "omnifocus",
            "omni focus",
            "focusrelay",
            "focus relay",
            "mcp server"
        ]
        let taskMarkers = [
            "inbox",
            "task",
            "tasks",
            "project",
            "projects",
            "available actions",
            "what did i complete",
            "completed today"
        ]
        let wantsOmniFocusData = omniFocusMarkers.contains { normalized.contains($0) }
        let wantsTaskData = taskMarkers.contains { normalized.contains($0) }
        return wantsOmniFocusData && wantsTaskData
    }

    nonisolated static func ownerDirectChatJID(ownerID: Int64?) -> String? {
        guard let ownerID else { return nil }
        return "telegram_\(ownerID)@direct"
    }

    nonisolated static func normalizedScheduledTaskChatJID(
        groupFolder: String,
        targetChatJID: String,
        ownerDirectChatJID: String?
    ) -> String {
        guard groupFolder == "telegram-direct", let ownerDirectChatJID else {
            return targetChatJID
        }
        return ownerDirectChatJID
    }

    nonisolated static func requiresPreRunTaskSnapshot(for prompt: String) -> Bool {
        guard case .command(let command) = SlashCommandParser.parse(prompt) else {
            return false
        }
        switch command {
        case .tasks, .schedule, .pause, .resume, .cancel:
            return true
        default:
            return false
        }
    }

    nonisolated static func scheduledContextMode(for task: ScheduledTaskRow) -> String {
        if scheduledPromptRequiresToolExecution(task.prompt) {
            return "isolated"
        }
        return task.contextMode
    }

    private func janitorLoop() async {
        let intervalSeconds = max(10, runtimeConfig.sessionJanitorIntervalSec)
        let staleClaimAge = max(30, runtimeConfig.staleClaimReapAgeSec)
        while !Task.isCancelled, !shuttingDown {
            await sessionManager.sweepStaleContainers()
            do {
                let reclaimed = try store.reclaimStaleClaimedOutbound(olderThanSeconds: staleClaimAge)
                if reclaimed > 0 {
                    logger.info("Reclaimed stale claimed outbound rows count=\(reclaimed) ageSec=\(staleClaimAge)")
                }
            } catch {
                logger.debug("Stale-claim reaper skipped: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(intervalSeconds))
        }
    }

    private func finalizeScheduledTask(
        job: QueueJob,
        response: ContainerResponsePayload,
        startedAt: Date
    ) async throws {
        guard let taskID = job.scheduledTaskID,
              let task = try store.getTask(taskID: taskID) else {
            releaseScheduledTask(job.scheduledTaskID)
            return
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let resultSummary: String
        if let result = response.result, !result.isEmpty {
            resultSummary = result.prefix(300).description
        } else if let error = response.error, !error.isEmpty {
            resultSummary = "Error: \(error.prefix(240))"
        } else {
            resultSummary = "Completed"
        }

        let scheduledCause = ScheduledRunFailureClassifier.classify(
            status: response.status,
            detail: response.error
        )
        if let decision = retryDecision(taskID: task.id, cause: scheduledCause) {
            let retryNextRun = isoNow(addingSeconds: decision.delaySec)
            let retrySummary = "Transient failure (\(scheduledCause?.rawValue ?? "unknown")); retry \(decision.attempt)/\(scheduledRetryMaxAttempts) in \(decision.delaySec)s"
            try store.updateTaskAfterRun(taskID: task.id, nextRun: retryNextRun, resultSummary: retrySummary)
            try store.logTaskRun(
                TaskRunLogRow(
                    taskID: task.id,
                    runAt: isoNow(),
                    durationMs: durationMs,
                    status: "error",
                    result: response.result,
                    error: response.error
                )
            )
            logger.warning(
                "Scheduled retry queued taskID=\(task.id) cause=\(scheduledCause?.rawValue ?? "unknown") attempt=\(decision.attempt)/\(scheduledRetryMaxAttempts) delaySec=\(decision.delaySec)"
            )
            releaseScheduledTask(taskID)
            return
        }

        clearScheduledRetryState(taskID: task.id)
        let nextRun = nextRunISO(for: task)
        try store.updateTaskAfterRun(taskID: task.id, nextRun: nextRun, resultSummary: resultSummary)
        if let scheduledCause {
            let notice = Self.scheduledFailureNotice(
                taskID: task.id,
                cause: scheduledCause
            )
            let chunks = splitAssistantOutboundText(
                notice,
                assistantName: assistantName,
                for: job.channel
            )
            for chunk in chunks where !chunk.isEmpty {
                _ = try store.enqueueOutbound(
                    channel: job.channel,
                    chatJID: job.chatJID,
                    text: chunk
                )
            }
        }
        try store.logTaskRun(
            TaskRunLogRow(
                taskID: task.id,
                runAt: isoNow(),
                durationMs: durationMs,
                status: response.status == "success" ? "success" : "error",
                result: response.result,
                error: response.error
            )
        )
        releaseScheduledTask(taskID)
    }

    private func releaseScheduledTask(_ taskID: String?) {
        guard let taskID else { return }
        runningScheduledTaskIDs.remove(taskID)
    }

    private func writeTaskSnapshot(for group: RegisteredGroupRow) async throws {
        try await sessionManager.ensureSession(for: group)
        guard let ipc = await sessionManager.ipcPaths(for: group.folder) else { return }

        let includeAll = group.folder == "main"
        let tasks = try store.listTasks(
            for: includeAll ? nil : group.folder,
            includeAll: includeAll
        )

        let payload: [[String: Any]] = tasks.map {
            [
                "id": $0.id,
                "groupFolder": $0.groupFolder,
                "prompt": $0.prompt,
                "schedule_type": $0.scheduleType,
                "schedule_value": $0.scheduleValue,
                "status": $0.status,
                "next_run": $0.nextRun as Any,
                "scheduler_time_zone": schedulerTimeZone.identifier
            ]
        }

        let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let fileURL = ipc.ipcRoot.appendingPathComponent("current_tasks.json")
        try json.write(to: fileURL, options: .atomic)
    }

    private func processIpcArtifacts(sourceGroup: RegisteredGroupRow) async throws -> IPCProcessingOutcome {
        guard let ipc = await sessionManager.ipcPaths(for: sourceGroup.folder) else { return IPCProcessingOutcome() }
        try await processTaskIPC(in: ipc.tasksDir, sourceGroup: sourceGroup)
        let outboundFromIPC = try await processMessageIPC(in: ipc.messagesDir, sourceGroup: sourceGroup)
        try await writeTaskSnapshot(for: sourceGroup)
        return IPCProcessingOutcome(outboundMessagesFromIPC: outboundFromIPC)
    }

    private func processMessageIPC(in directory: URL, sourceGroup: RegisteredGroupRow) async throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var commands: [IPCMessageCommand] = []
        for file in files {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("Ignoring malformed IPC message payload: \(file.path)")
                continue
            }

            let type = stringValue(object, keys: ["type"]).lowercased()
            guard type == "send_message" || type == "message" else { continue }

            let targetJID = stringValue(object, keys: ["chat_jid", "chatJid"])
            let text = stringValue(object, keys: ["message", "text"])
            let attachmentPath = stringValue(object, keys: ["attachment_path", "attachmentPath"])
            let caption = nonEmptyStringValue(object, keys: ["caption"])
            guard !targetJID.isEmpty else { continue }

            let isMain = sourceGroup.folder == "main"
            if !isMain {
                if let target = try store.fetchGroup(jid: targetJID) {
                    guard target.folder == sourceGroup.folder else {
                        logger.warning("Blocked cross-group send_message from \(sourceGroup.folder) to \(target.folder)")
                        continue
                    }
                } else if targetJID != sourceGroup.jid {
                    logger.warning("Blocked send_message to unknown target from non-main group \(sourceGroup.folder)")
                    continue
                }
            }

            let channel = channelForChatJID(targetJID)
            let resolvedAttachmentPath: String?
            if attachmentPath.isEmpty {
                resolvedAttachmentPath = nil
            } else if let mapped = Self.resolveAttachmentHostPath(
                containerPath: attachmentPath,
                sourceGroupFolder: sourceGroup.folder,
                groupsDir: runtimeConfig.groupsDir
            ) {
                guard FileManager.default.fileExists(atPath: mapped) else {
                    logger.warning("Ignoring send_message attachment; file not found at host path \(mapped)")
                    continue
                }
                resolvedAttachmentPath = mapped
            } else {
                logger.warning("Ignoring send_message attachment; invalid container path \(attachmentPath)")
                continue
            }

            let resolvedKind = resolvedAttachmentPath == nil ? "text" : "attachment"
            if text.isEmpty, resolvedAttachmentPath == nil {
                continue
            }
            let resolvedCaption = caption ?? (resolvedAttachmentPath != nil && !text.isEmpty ? text : nil)
            commands.append(
                IPCMessageCommand(
                    channel: channel,
                    chatJID: targetJID,
                    text: text,
                    kind: resolvedKind,
                    attachmentPath: resolvedAttachmentPath,
                    caption: resolvedCaption
                )
            )
        }

        let collapsed = Self.collapseLatestOutboundMessages(commands)
        if commands.count > collapsed.count {
            logger.info(
                "Collapsed duplicate IPC send_message payloads sourceGroup=\(sourceGroup.folder) original=\(commands.count) collapsed=\(collapsed.count)"
            )
        }

        var enqueued = 0
        for command in collapsed {
            let chunks = splitOutboundText(command.text, for: command.channel)
            if command.kind == "attachment", let attachmentPath = command.attachmentPath {
                _ = try store.enqueueOutbound(
                    channel: command.channel,
                    chatJID: command.chatJID,
                    text: command.text,
                    kind: command.kind,
                    attachmentPath: attachmentPath,
                    caption: command.caption
                )
                enqueued += 1
                continue
            }

            for chunk in chunks where !chunk.isEmpty {
                _ = try store.enqueueOutbound(
                    channel: command.channel,
                    chatJID: command.chatJID,
                    text: chunk
                )
                enqueued += 1
            }
        }
        return enqueued
    }

    private func processTaskIPC(in directory: URL, sourceGroup: RegisteredGroupRow) async throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("Ignoring malformed IPC task payload: \(file.path)")
                continue
            }

            let type = stringValue(object, keys: ["type"]).lowercased()
            switch type {
            case "schedule_task":
                try await handleScheduleTaskIPC(object, sourceGroup: sourceGroup)
            case "pause_task":
                try await handleTaskStatusIPC(object, sourceGroup: sourceGroup, status: "paused")
            case "resume_task":
                try await handleTaskStatusIPC(object, sourceGroup: sourceGroup, status: "active")
            case "cancel_task":
                try await handleCancelTaskIPC(object, sourceGroup: sourceGroup)
            default:
                continue
            }
        }
    }

    private func handleScheduleTaskIPC(_ payload: [String: Any], sourceGroup: RegisteredGroupRow) async throws {
        let isMain = sourceGroup.folder == "main"
        let targetGroupFolder = stringValue(payload, keys: ["group_folder", "groupFolder"]).isEmpty
            ? sourceGroup.folder
            : stringValue(payload, keys: ["group_folder", "groupFolder"])

        if !isMain && targetGroupFolder != sourceGroup.folder {
            logger.warning("Blocked unauthorized schedule_task from \(sourceGroup.folder) -> \(targetGroupFolder)")
            return
        }

        guard let targetGroup = try store.findGroup(folder: targetGroupFolder) else {
            logger.warning("Cannot schedule task for unknown group folder \(targetGroupFolder)")
            return
        }

        let prompt = nonEmptyStringValue(payload, keys: ["prompt", "description"])
        guard let prompt else {
            logger.warning("schedule_task payload missing prompt/description")
            return
        }

        var scheduleType = stringValue(payload, keys: ["schedule_type"]).lowercased()
        var scheduleValue = stringValue(payload, keys: ["schedule_value"])
        let providedTime = stringValue(payload, keys: ["time"])

        if scheduleType == "recurring" {
            scheduleType = "cron"
            if scheduleValue.isEmpty {
                scheduleValue = hhmmToCron(providedTime) ?? "0 8 * * *"
            }
        } else if scheduleType == "cron", scheduleValue.isEmpty {
            scheduleValue = hhmmToCron(providedTime) ?? "0 8 * * *"
        }

        guard ["cron", "interval", "once"].contains(scheduleType), !scheduleValue.isEmpty else {
            logger.warning("Ignoring invalid schedule_task payload (type/value): \(scheduleType) / \(scheduleValue)")
            return
        }

        let contextMode = nonEmptyStringValue(payload, keys: ["context_mode"]) ?? "isolated"
        let nextRun = nextRunISO(scheduleType: scheduleType, scheduleValue: scheduleValue)
        let taskID = nonEmptyStringValue(payload, keys: ["task_id"]) ?? "task-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"

        let row = ScheduledTaskRow(
            id: taskID,
            groupFolder: targetGroup.folder,
            chatJID: Self.normalizedScheduledTaskChatJID(
                groupFolder: targetGroup.folder,
                targetChatJID: targetGroup.jid,
                ownerDirectChatJID: ownerDirectChatJID
            ),
            prompt: prompt,
            scheduleType: scheduleType,
            scheduleValue: scheduleValue,
            contextMode: contextMode,
            nextRun: nextRun,
            status: "active",
            createdAt: isoNow()
        )
        try store.createTask(row)
    }

    private func handleTaskStatusIPC(
        _ payload: [String: Any],
        sourceGroup: RegisteredGroupRow,
        status: String
    ) async throws {
        let requestedTaskID = stringValue(payload, keys: ["task_id", "taskId"])
        guard !requestedTaskID.isEmpty else { return }
        guard let task = try resolveTask(taskID: requestedTaskID) else { return }
        let isMain = sourceGroup.folder == "main"
        guard isMain || task.groupFolder == sourceGroup.folder else {
            logger.warning("Blocked unauthorized task status mutation for \(requestedTaskID)")
            return
        }
        try store.updateTaskStatus(taskID: task.id, status: status)
    }

    private func handleCancelTaskIPC(_ payload: [String: Any], sourceGroup: RegisteredGroupRow) async throws {
        let requestedTaskID = stringValue(payload, keys: ["task_id", "taskId"])
        guard !requestedTaskID.isEmpty else { return }
        guard let task = try resolveTask(taskID: requestedTaskID) else { return }
        let isMain = sourceGroup.folder == "main"
        guard isMain || task.groupFolder == sourceGroup.folder else {
            logger.warning("Blocked unauthorized task cancellation for \(requestedTaskID)")
            return
        }
        try store.deleteTask(taskID: task.id)
        runningScheduledTaskIDs.remove(task.id)
    }

    private func resolveTask(taskID: String) throws -> ScheduledTaskRow? {
        if let exact = try store.getTask(taskID: taskID) {
            return exact
        }
        return try store.getTaskCaseInsensitive(taskID: taskID)
    }

    private func schedulerLoop() async {
        while !Task.isCancelled {
            await enqueueDueScheduledTasks(reason: "poll")

            try? await Task.sleep(for: .seconds(30))
        }
    }

    nonisolated static func schedulableDueTasks(
        from due: [ScheduledTaskRow],
        runningIDs: Set<String>
    ) -> [ScheduledTaskRow] {
        due.filter { !runningIDs.contains($0.id) }
    }

    nonisolated static func startupCatchUpNotice(taskID: String?, prompt: String) -> String {
        let idText = taskID?.isEmpty == false ? (taskID ?? "scheduled task") : "scheduled task"
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String
        if trimmed.count > 80 {
            summary = String(trimmed.prefix(80)) + "..."
        } else if trimmed.isEmpty {
            summary = "(no description)"
        } else {
            summary = trimmed
        }
        return """
Andy: I was offline earlier, so I'm running your missed scheduled task now.
• Task ID: \(idText)
• Summary: \(summary)
"""
    }

    nonisolated static func scheduledFailureNotice(
        taskID: String?,
        cause: ScheduledRunFailureCause
    ) -> String {
        let idText = taskID?.isEmpty == false ? (taskID ?? "scheduled task") : "scheduled task"
        let hint: String
        switch cause {
        case .providerRateLimit:
            hint = "The provider hit a rate limit. I will try again on the next scheduled run."
        case .providerTimeout:
            hint = "The provider timed out. Please check connectivity and provider health."
        case .networkOffline:
            hint = "Network connectivity failed. Please check internet access on the host."
        case .tokenOverflow:
            hint = "The report prompt/context is too large. Please shorten the scheduled prompt."
        case .missingToolCalls:
            hint = "The model did not execute required tools. A quick retry was attempted."
        case .staleContent:
            hint = "No fresh dated sources were found in the report output. I will retry and only send fresh updates."
        case .toolError:
            hint = "A required tool failed during execution. Please retry or inspect tool health."
        case .unknown:
            hint = "The run failed for an unknown reason. Please check scheduler diagnostics."
        }
        return """
Your scheduled task run failed.
• Task ID: \(idText)
• Cause: \(cause.rawValue)
• Hint: \(hint)
"""
    }

    nonisolated static func shouldScheduleTransientRetry(
        cause: ScheduledRunFailureCause?,
        retryAttempt: Int,
        maxAttempts: Int
    ) -> Bool {
        guard maxAttempts > 0, retryAttempt > 0 else { return false }
        guard retryAttempt <= maxAttempts else { return false }
        return ScheduledRunFailureClassifier.isTransient(cause)
    }

    nonisolated static func retryBackoffSeconds(
        forRetryAttempt retryAttempt: Int,
        initialBackoffSec: Int,
        maxBackoffSec: Int
    ) -> Int {
        let safeInitial = max(1, initialBackoffSec)
        let safeMax = max(safeInitial, maxBackoffSec)
        let exponent = max(0, retryAttempt - 1)
        let scaled = safeInitial * Int(pow(2.0, Double(exponent)))
        return min(scaled, safeMax)
    }

    nonisolated static func retryBackoffSeconds(
        for cause: ScheduledRunFailureCause?,
        retryAttempt: Int,
        initialBackoffSec: Int,
        maxBackoffSec: Int
    ) -> Int {
        if cause == .missingToolCalls {
            let fastInitial = min(max(5, initialBackoffSec), 15)
            return retryBackoffSeconds(
                forRetryAttempt: retryAttempt,
                initialBackoffSec: fastInitial,
                maxBackoffSec: maxBackoffSec
            )
        }
        return retryBackoffSeconds(
            forRetryAttempt: retryAttempt,
            initialBackoffSec: initialBackoffSec,
            maxBackoffSec: maxBackoffSec
        )
    }

    private func enqueueDueScheduledTasks(reason: String) async {
        do {
            let due = try store.dueTasks(nowISO: isoNow())
            let schedulable = Self.schedulableDueTasks(
                from: due,
                runningIDs: runningScheduledTaskIDs
            )
            guard !schedulable.isEmpty else { return }

            var enqueuedCount = 0
            for task in schedulable {
                guard let group = try store.findGroup(folder: task.groupFolder) else {
                    continue
                }
                runningScheduledTaskIDs.insert(task.id)
                let requestID = "sched-\(task.id)-\(Int(Date().timeIntervalSince1970))"
                let job = QueueJob(
                    requestID: requestID,
                    channel: channelForChatJID(task.chatJID),
                    chatJID: task.chatJID,
                    sender: "scheduler",
                    senderName: "scheduler",
                    content: task.prompt,
                    timestamp: isoNow(),
                    messageID: requestID,
                    group: group,
                    isScheduledTask: true,
                    isStartupCatchUp: reason == "startup",
                    scheduledTaskID: task.id,
                    contextMode: Self.scheduledContextMode(for: task),
                    enqueuedAt: Date()
                )
                await queue.enqueue(job)
                enqueuedCount += 1
            }

            if enqueuedCount > 0 {
                logger.info("Scheduled catch-up enqueued count=\(enqueuedCount) reason=\(reason)")
            }
        } catch {
            logger.error("Scheduler catch-up failed reason=\(reason): \(error.localizedDescription)")
        }
    }

    private func retryDecision(
        taskID: String,
        cause: ScheduledRunFailureCause?
    ) -> (attempt: Int, delaySec: Int)? {
        let attempt = (scheduledRetryAttempts[taskID] ?? 0) + 1
        guard Self.shouldScheduleTransientRetry(
            cause: cause,
            retryAttempt: attempt,
            maxAttempts: scheduledRetryMaxAttempts
        ) else {
            scheduledRetryAttempts.removeValue(forKey: taskID)
            return nil
        }
        scheduledRetryAttempts[taskID] = attempt
        let delaySec = Self.retryBackoffSeconds(
            for: cause,
            retryAttempt: attempt,
            initialBackoffSec: scheduledRetryInitialBackoffSec,
            maxBackoffSec: scheduledRetryMaxBackoffSec
        )
        return (attempt: attempt, delaySec: delaySec)
    }

    private func clearScheduledRetryState(taskID: String) {
        scheduledRetryAttempts.removeValue(forKey: taskID)
    }

    private func isoNow(addingSeconds seconds: Int) -> String {
        isoFormatter.string(from: Date().addingTimeInterval(Double(max(0, seconds))))
    }

    private func prewarmGroupSessions() async {
        do {
            let groups = try store.listGroups(limit: prewarmLimit)
            guard !groups.isEmpty else {
                logger.info("Group prewarm skipped: no registered groups")
                return
            }

            logger.info("Prewarming up to \(prewarmLimit) group container sessions")
            for group in groups.prefix(prewarmLimit) {
                if Task.isCancelled || shuttingDown { return }

                let start = Date()
                do {
                    try await sessionManager.ensureSession(for: group)
                    let elapsedMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
                    logger.info("Prewarmed group session group=\(group.folder) elapsedMs=\(elapsedMs)")
                } catch {
                    logger.warning("Failed to prewarm group session group=\(group.folder) error=\(error.localizedDescription)")
                }
            }
        } catch {
            logger.warning("Group prewarm skipped: \(error.localizedDescription)")
        }
    }

    private func scheduleWorkingAck(for job: QueueJob) {
        guard workingAckEnabled, !job.isScheduledTask else { return }
        let requestID = job.requestID
        let channel = job.channel
        let chatJID = job.chatJID
        let thresholdNs = UInt64(max(workingAckThresholdMs, 1000)) * 1_000_000
        let repeatNs = UInt64(max(workingAckRepeatIntervalMs, 1000)) * 1_000_000
        let maxAckUpdates = workingAckMaxUpdates

        if let existing = workingAckTasks.removeValue(forKey: requestID) {
            existing.cancel()
        }
        workingAckTasks[requestID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: thresholdNs)
            } catch {
                return
            }

            var repeatUpdate = false
            var sentCount = 0
            while !Task.isCancelled,
                  Self.shouldSendWorkingAck(sentCount: sentCount, maxUpdates: maxAckUpdates) {
                await self?.emitWorkingAckIfPending(
                    requestID: requestID,
                    channel: channel,
                    chatJID: chatJID,
                    repeatUpdate: repeatUpdate
                )
                sentCount += 1
                repeatUpdate = true
                guard Self.shouldSendWorkingAck(sentCount: sentCount, maxUpdates: maxAckUpdates) else {
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: repeatNs)
                } catch {
                    break
                }
            }
        }
    }

    private func cancelWorkingAck(requestID: String) {
        guard let task = workingAckTasks.removeValue(forKey: requestID) else { return }
        task.cancel()
    }

    private func emitWorkingAckIfPending(
        requestID: String,
        channel: String,
        chatJID: String,
        repeatUpdate: Bool
    ) async {
        guard let task = workingAckTasks[requestID] else { return }
        if task.isCancelled || Task.isCancelled || shuttingDown {
            return
        }
        do {
            _ = try store.enqueueOutbound(
                channel: channel,
                chatJID: chatJID,
                text: Self.workingAckMessage(assistantName: assistantName, repeatUpdate: repeatUpdate)
            )
            logger.info(
                "Sent working acknowledgment request=\(requestID) channel=\(channel) chat=\(chatJID) repeat=\(repeatUpdate)"
            )
        } catch {
            logger.warning(
                "Failed to enqueue working acknowledgment request=\(requestID) repeat=\(repeatUpdate): \(error.localizedDescription)"
            )
        }
    }

    nonisolated static func workingAckMessage(assistantName: String, repeatUpdate: Bool) -> String {
        if repeatUpdate {
            return "\(assistantName): Still working on your request, thanks for your patience..."
        }
        return "\(assistantName): Working on it, still processing your request..."
    }

    nonisolated static func shouldSendWorkingAck(sentCount: Int, maxUpdates: Int) -> Bool {
        sentCount < max(0, maxUpdates)
    }

    private func recordLatency(totalMs: Int, timedOut: Bool) {
        completedJobs += 1
        if timedOut {
            timeoutJobs += 1
        }
        latencySamplesMs.append(totalMs)
        if latencySamplesMs.count > latencyWindowSize {
            latencySamplesMs.removeFirst(latencySamplesMs.count - latencyWindowSize)
        }
        if completedJobs % 20 == 0 {
            logSLOIfBreached()
        }
    }

    private func logSLOIfBreached() {
        let summary = latencySummary()
        guard summary.sampleCount >= 20 else { return }

        var reasons: [String] = []
        if let p50 = summary.p50, p50 > latencySLOP50Ms {
            reasons.append("p50=\(p50)ms>\(latencySLOP50Ms)ms")
        }
        if let p95 = summary.p95, p95 > latencySLOP95Ms {
            reasons.append("p95=\(p95)ms>\(latencySLOP95Ms)ms")
        }
        if summary.timeoutRate > timeoutAlertRate {
            reasons.append("timeoutRate=\(String(format: "%.3f", summary.timeoutRate))>\(String(format: "%.3f", timeoutAlertRate))")
        }
        if summary.retryRate > retryAlertRate {
            reasons.append("retryRate=\(String(format: "%.3f", summary.retryRate))>\(String(format: "%.3f", retryAlertRate))")
        }
        guard !reasons.isEmpty else { return }

        logger.warning(
            "Latency SLO warning sample=\(summary.sampleCount) p50=\(summary.p50 ?? -1)ms p95=\(summary.p95 ?? -1)ms timeoutRate=\(String(format: "%.3f", summary.timeoutRate)) retryRate=\(String(format: "%.3f", summary.retryRate)) reason=\(reasons.joined(separator: ","))"
        )
    }

    private func latencySummary() -> LatencySummary {
        let sampleCount = latencySamplesMs.count
        guard sampleCount > 0 else {
            return LatencySummary(
                sampleCount: 0,
                p50: nil,
                p95: nil,
                timeoutRate: 0,
                retryRate: totalInboundEvents == 0 ? 0 : Double(duplicateInboundEvents) / Double(totalInboundEvents)
            )
        }

        let sorted = latencySamplesMs.sorted()
        let p50 = percentile(sorted: sorted, quantile: 0.50)
        let p95 = percentile(sorted: sorted, quantile: 0.95)
        return LatencySummary(
            sampleCount: sampleCount,
            p50: p50,
            p95: p95,
            timeoutRate: completedJobs == 0 ? 0 : Double(timeoutJobs) / Double(completedJobs),
            retryRate: totalInboundEvents == 0 ? 0 : Double(duplicateInboundEvents) / Double(totalInboundEvents)
        )
    }

    private func percentile(sorted: [Int], quantile: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(1.0, max(0.0, quantile))
        let rank = Int((Double(sorted.count - 1) * clamped).rounded(.up))
        let index = min(max(rank, 0), sorted.count - 1)
        return sorted[index]
    }

    private func isTimeoutLike(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowered = value.lowercased()
        return lowered.contains("timed out") || lowered.contains("timeout")
    }

    private func stringValue(_ payload: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = payload[key] as? String {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private func nonEmptyStringValue(_ payload: [String: Any], keys: [String]) -> String? {
        let value = stringValue(payload, keys: keys)
        return value.isEmpty ? nil : value
    }

    private func channelForChatJID(_ jid: String) -> String {
        ChannelResolver.resolveOutboundChannel(forChatJID: jid)
    }

    private func handleTelegramDirectCommandIfNeeded(
        event: InboundEventRequest,
        group: RegisteredGroupRow
    ) throws -> InboundEventResponse? {
        guard event.channel == "telegram", event.is_direct else { return nil }
        let trimmed = event.content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let ocrResponse = deterministicPhotoOCRResponseIfNeeded(for: event, prompt: trimmed) {
            let chunks = splitAssistantOutboundText(
                ocrResponse,
                assistantName: assistantName,
                for: event.channel
            )
            for chunk in chunks where !chunk.isEmpty {
                _ = try store.enqueueOutbound(
                    channel: event.channel,
                    chatJID: event.chat_jid,
                    text: chunk
                )
            }
            logger.info(
                "Handled Telegram direct OCR request chat=\(event.chat_jid) group=\(group.folder) messageID=\(event.message_id)"
            )
            return InboundEventResponse(
                accepted: true,
                group_folder: group.folder,
                request_id: nil
            )
        }

        let message: String
        let commandNameForLogs: String
        switch SlashCommandParser.parse(trimmed) {
        case .notCommand, .unknown:
            return nil
        case .invalid(let usageError):
            guard isHostTelegramDirectCommandName(usageError.command) else {
                return nil
            }
            message = "\(usageError.message)\nUsage: \(usageError.usage)"
            commandNameForLogs = usageError.command
        case .command(let command):
            guard isHostTelegramDirectCommand(command) else {
                return nil
            }
            message = try runTelegramDirectCommand(command, sourceGroup: group)
            commandNameForLogs = telegramDirectCommandName(command)
        }

        let chunks = splitAssistantOutboundText(
            message,
            assistantName: assistantName,
            for: event.channel
        )
        for chunk in chunks where !chunk.isEmpty {
            _ = try store.enqueueOutbound(
                channel: event.channel,
                chatJID: event.chat_jid,
                text: chunk
            )
        }
        logger.info(
            "Handled Telegram direct command chat=\(event.chat_jid) group=\(group.folder) command=\(commandNameForLogs)"
        )
        return InboundEventResponse(
            accepted: true,
            group_folder: group.folder,
            request_id: nil
        )
    }

    private func deterministicPhotoOCRResponseIfNeeded(
        for event: InboundEventRequest,
        prompt: String
    ) -> String? {
        guard isPhotoOCRIntent(prompt),
              let attachments = event.attachments,
              attachments.contains(where: { $0.kind == "photo" }) else {
            return nil
        }

        let ocrText = attachments
            .compactMap(\.ocrText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let imagePath = attachments
            .compactMap(\.localPath)
            .first(where: { !$0.isEmpty }) ?? "unavailable"

        if ocrText.isEmpty {
            return """
            Detected text:
            none

            Confidence: Low
            Potential corrections: none
            Image path: \(imagePath)
            Please send a closer, well-lit photo focused on the text for a better read.
            """
        }

        let normalizedOCRText = normalizeOCRTextForDisplay(ocrText)
        let ambiguityHints = ocrAmbiguityHints(for: normalizedOCRText)
        let confidence = ocrConfidenceBand(for: normalizedOCRText, ambiguityCount: ambiguityHints.count)
        let correctionLine = ambiguityHints.isEmpty
            ? "none"
            : ambiguityHints.joined(separator: "; ")
        let includeDebugPath = shouldIncludeOCRImagePath(prompt: prompt, confidence: confidence)
        let lowConfidenceHint = confidence == "Low"
            ? "\nPlease send a closer, well-lit photo focused on the text for a better read."
            : ""
        let imagePathLine = includeDebugPath
            ? "\nImage path: \(imagePath)"
            : ""

        return """
        Detected text:
        \(normalizedOCRText)

        Confidence: \(confidence)
        Potential corrections: \(correctionLine)\(imagePathLine)\(lowConfidenceHint)
        """
    }

    private func isPhotoOCRIntent(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let markers = [
            "text in this photo",
            "text is in this photo",
            "text in this image",
            "text is in this image",
            "what is the text",
            "what's the text",
            "extract text",
            "read text",
            "ocr"
        ]
        return markers.contains { lowered.contains($0) }
    }

    private func ocrConfidenceBand(for text: String, ambiguityCount: Int) -> String {
        if text.count < 4 {
            return "Low"
        }
        if ambiguityCount == 0 {
            return "High"
        }
        if ambiguityCount <= 2 {
            return "Medium"
        }
        return "Low"
    }

    private func ocrAmbiguityHints(for text: String) -> [String] {
        var hints: [String] = []
        let letters = CharacterSet.letters
        let digits = CharacterSet.decimalDigits

        if text.contains("|") {
            hints.append("`|` may be `1` or `I`")
        }

        if containsAmbiguousPair(
            text: text,
            primary: "0",
            secondary: "o",
            primaryNeighborSet: letters,
            secondaryNeighborSet: digits
        ) {
            hints.append("`0` and `O` may be mixed")
        }

        if containsAmbiguousPair(
            text: text,
            primary: "1",
            secondary: "l",
            primaryNeighborSet: letters,
            secondaryNeighborSet: digits
        ) {
            hints.append("`1` and `l` may be mixed")
        }
        return hints
    }

    private func normalizeOCRTextForDisplay(_ text: String) -> String {
        let rawLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawLines.isEmpty else { return text }

        var merged: [String] = []
        var index = 0
        while index < rawLines.count {
            var current = rawLines[index]
            if current.hasSuffix("-"), index + 1 < rawLines.count {
                let next = rawLines[index + 1]
                if shouldJoinAfterHyphen(next) {
                    current += next
                    index += 1
                }
            }
            merged.append(current)
            index += 1
        }
        return merged.joined(separator: "\n")
    }

    private func shouldJoinAfterHyphen(_ nextLine: String) -> Bool {
        guard let first = nextLine.first else { return false }
        return first.isNumber || first.isLetter
    }

    private func shouldIncludeOCRImagePath(prompt: String, confidence: String) -> Bool {
        if confidence == "Low" {
            return true
        }
        let lowered = prompt.lowercased()
        return lowered.contains("debug")
            || lowered.contains("path")
            || lowered.contains("trace")
            || lowered.contains("raw")
    }

    private func containsAmbiguousPair(
        text: String,
        primary: Character,
        secondary: Character,
        primaryNeighborSet: CharacterSet,
        secondaryNeighborSet: CharacterSet
    ) -> Bool {
        let chars = Array(text.lowercased())
        guard chars.count >= 2 else { return false }

        func hasNeighbor(at index: Int, in set: CharacterSet) -> Bool {
            if index > 0, scalarBelongs(chars[index - 1], to: set) {
                return true
            }
            if index + 1 < chars.count, scalarBelongs(chars[index + 1], to: set) {
                return true
            }
            return false
        }

        for index in chars.indices {
            if chars[index] == primary, hasNeighbor(at: index, in: primaryNeighborSet) {
                return true
            }
            if chars[index] == secondary, hasNeighbor(at: index, in: secondaryNeighborSet) {
                return true
            }
        }
        return false
    }

    private func scalarBelongs(_ character: Character, to set: CharacterSet) -> Bool {
        for scalar in character.unicodeScalars where set.contains(scalar) {
            return true
        }
        return false
    }

    private func isHostTelegramDirectCommand(_ command: SlashCommand) -> Bool {
        switch command {
        case .tasks, .schedule, .pause, .resume, .cancel:
            return true
        default:
            return false
        }
    }

    private func isHostTelegramDirectCommandName(_ command: String) -> Bool {
        switch command.lowercased() {
        case "/tasks", "/schedule", "/pause", "/resume", "/cancel":
            return true
        default:
            return false
        }
    }

    private func telegramDirectCommandName(_ command: SlashCommand) -> String {
        switch command {
        case .tasks:
            return "/tasks"
        case .schedule:
            return "/schedule"
        case .pause:
            return "/pause"
        case .resume:
            return "/resume"
        case .cancel:
            return "/cancel"
        case .skills:
            return "/skills"
        case .reloadSkills:
            return "/reload-skills"
        case .mcpStatus:
            return "/mcp-status"
        case .mcpReload:
            return "/mcp-reload"
        case .mcpCLI:
            return "/mcp-cli"
        case .more:
            return "/more"
        case .help:
            return "/help"
        }
    }

    private func runTelegramDirectCommand(
        _ command: SlashCommand,
        sourceGroup: RegisteredGroupRow
    ) throws -> String {
        switch command {
        case .tasks:
            let tasks = try store.listTasks(for: sourceGroup.folder, includeAll: false)
            guard !tasks.isEmpty else {
                return "No scheduled tasks for this chat."
            }
            let lines = tasks.prefix(20).map { task in
                let next = task.nextRun ?? "none"
                return "- \(task.id) [\(task.status)] \(task.scheduleType):\(task.scheduleValue) next:\(next) :: \(task.prompt)"
            }
            return "Scheduled tasks (\(tasks.count)):\n" + lines.joined(separator: "\n")

        case .schedule(let time, let prompt):
            return try scheduleTaskFromTelegramCommand(
                scheduleToken: time,
                prompt: prompt,
                sourceGroup: sourceGroup
            )

        case .pause(let taskID):
            let requestedTaskID = taskID
            guard let task = try resolveTask(taskID: requestedTaskID) else {
                return "Task not found: \(requestedTaskID)"
            }
            try store.updateTaskStatus(taskID: task.id, status: "paused")
            return "Paused task \(task.id)."

        case .resume(let taskID):
            let requestedTaskID = taskID
            guard let task = try resolveTask(taskID: requestedTaskID) else {
                return "Task not found: \(requestedTaskID)"
            }
            try store.updateTaskStatus(taskID: task.id, status: "active")
            return "Resumed task \(task.id)."

        case .cancel(let taskID):
            let requestedTaskID = taskID
            guard let task = try resolveTask(taskID: requestedTaskID) else {
                return "Task not found: \(requestedTaskID)"
            }
            try store.deleteTask(taskID: task.id)
            runningScheduledTaskIDs.remove(task.id)
            return "Canceled task \(task.id)."

        case .skills, .reloadSkills, .mcpStatus, .mcpReload, .mcpCLI, .more, .help:
            return telegramCommandUsage()
        }
    }

    private func scheduleTaskFromTelegramCommand(
        scheduleToken: String,
        prompt: String,
        sourceGroup: RegisteredGroupRow
    ) throws -> String {
        guard let cronValue = hhmmToCron(scheduleToken) else {
            return "Usage: /schedule <HH:MM> <prompt>"
        }

        let taskID = "task-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
        let nextRun = nextRunISO(scheduleType: "cron", scheduleValue: cronValue)
        let row = ScheduledTaskRow(
            id: taskID,
            groupFolder: sourceGroup.folder,
            chatJID: Self.normalizedScheduledTaskChatJID(
                groupFolder: sourceGroup.folder,
                targetChatJID: sourceGroup.jid,
                ownerDirectChatJID: ownerDirectChatJID
            ),
            prompt: prompt,
            scheduleType: "cron",
            scheduleValue: cronValue,
            contextMode: "isolated",
            nextRun: nextRun,
            status: "active",
            createdAt: isoNow()
        )
        try store.createTask(row)
        return "Scheduled task \(taskID) at \(scheduleToken) daily."
    }

    private func telegramCommandUsage() -> String {
        """
        Supported commands:
        /tasks
        /schedule <HH:MM> <prompt>
        /pause <task_id>
        /resume <task_id>
        /cancel <task_id>
        """
    }

    private func nextRunISO(for task: ScheduledTaskRow) -> String? {
        nextRunISO(scheduleType: task.scheduleType, scheduleValue: task.scheduleValue)
    }

    private func nextRunISO(scheduleType: String, scheduleValue: String) -> String? {
        switch scheduleType {
        case "once":
            let date = isoFormatter.date(from: scheduleValue)
            return date.map { isoFormatter.string(from: $0) }
        case "interval":
            guard let milliseconds = Int(scheduleValue), milliseconds > 0 else { return nil }
            let next = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
            return isoFormatter.string(from: next)
        case "cron":
            do {
                let next = try cronEngine.nextDate(
                    after: Date(),
                    expression: scheduleValue,
                    timeZone: schedulerTimeZone
                )
                return isoFormatter.string(from: next)
            } catch {
                logger.warning("Invalid cron expression \"\(scheduleValue)\": \(error.localizedDescription)")
                return nil
            }
        default:
            return nil
        }
    }

    private func hhmmToCron(_ hhmm: String) -> String? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return "\(minute) \(hour) * * *"
    }

    private func isoNow() -> String {
        isoFormatter.string(from: Date())
    }
}

private struct LatencySummary {
    let sampleCount: Int
    let p50: Int?
    let p95: Int?
    let timeoutRate: Double
    let retryRate: Double
}
