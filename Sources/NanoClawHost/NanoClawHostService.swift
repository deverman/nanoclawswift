import Foundation
import Logging
import CronEngineKit

actor NanoClawHostService {
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
    private let latencyWindowSize: Int
    private let latencySLOP50Ms: Int
    private let latencySLOP95Ms: Int
    private let timeoutAlertRate: Double
    private let retryAlertRate: Double
    private let isoFormatter = ISO8601DateFormatter()
    private var schedulerTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var shuttingDown = false
    private var runningScheduledTaskIDs: Set<String> = []
    private var workingAckTasks: [String: Task<Void, Never>] = [:]
    private var totalInboundEvents = 0
    private var duplicateInboundEvents = 0
    private var completedJobs = 0
    private var timeoutJobs = 0
    private var latencySamplesMs: [Int] = []

    private lazy var queue: GroupQueue = GroupQueue(
        maxConcurrentGroups: maxConcurrentGroups,
        logger: logger
    ) { [weak self] job in
        await self?.process(job: job)
    }

    init(
        logger: Logger,
        assistantName: String,
        runtimeConfig: HostRuntimeConfig,
        dataDir: String,
        databasePath: String,
        maxConcurrentGroups: Int
    ) throws {
        self.logger = logger
        self.assistantName = assistantName
        self.runtimeConfig = runtimeConfig
        self.maxConcurrentGroups = maxConcurrentGroups
        self.store = try SQLiteStore(dbPath: databasePath, dataDir: dataDir, logger: logger)
        self.sessionManager = ContainerSessionManager(config: runtimeConfig, logger: logger)
        self.cronEngine = VixieCronEngine()
        let prewarmRaw = ProcessInfo.processInfo.environment["NANOCLAW_PREWARM_GROUP_SESSIONS"]?.lowercased()
        self.prewarmEnabled = !(prewarmRaw == "0" || prewarmRaw == "false" || prewarmRaw == "no")
        self.prewarmLimit = max(
            0,
            Int(ProcessInfo.processInfo.environment["NANOCLAW_PREWARM_LIMIT"] ?? "3") ?? 3
        )
        let workingAckRaw = ProcessInfo.processInfo.environment["NANOCLAW_WORKING_ACK_ENABLED"]?.lowercased()
        self.workingAckEnabled = !(workingAckRaw == "0" || workingAckRaw == "false" || workingAckRaw == "no")
        self.workingAckThresholdMs = max(
            1000,
            Int(ProcessInfo.processInfo.environment["NANOCLAW_WORKING_ACK_THRESHOLD_MS"] ?? "8000") ?? 8000
        )
        self.latencyWindowSize = max(
            20,
            Int(ProcessInfo.processInfo.environment["NANOCLAW_LATENCY_WINDOW_SIZE"] ?? "200") ?? 200
        )
        let parsedP50 = max(
            1000,
            Int(ProcessInfo.processInfo.environment["NANOCLAW_LATENCY_SLO_P50_MS"] ?? "15000") ?? 15000
        )
        self.latencySLOP50Ms = parsedP50
        self.latencySLOP95Ms = max(
            parsedP50,
            Int(ProcessInfo.processInfo.environment["NANOCLAW_LATENCY_SLO_P95_MS"] ?? "60000") ?? 60000
        )
        self.timeoutAlertRate = Self.parseRate(
            ProcessInfo.processInfo.environment["NANOCLAW_TIMEOUT_ALERT_RATE"],
            fallback: 0.05
        )
        self.retryAlertRate = Self.parseRate(
            ProcessInfo.processInfo.environment["NANOCLAW_RETRY_ALERT_RATE"],
            fallback: 0.02
        )
        if let tzIdentifier = ProcessInfo.processInfo.environment["TZ"],
           let parsed = TimeZone(identifier: tzIdentifier) {
            self.schedulerTimeZone = parsed
        } else {
            self.schedulerTimeZone = .current
        }
    }

    func start() async {
        await sessionManager.sweepStaleContainers()
        schedulerTask = Task { [weak self] in
            await self?.schedulerLoop()
        }
        if prewarmEnabled, prewarmLimit > 0 {
            prewarmTask = Task { [weak self] in
                await self?.prewarmGroupSessions()
            }
        }
    }

    func shutdown() async {
        shuttingDown = true
        schedulerTask?.cancel()
        schedulerTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
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

        let requestID = "req-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
        let enqueuedAt = Date()
        let job = QueueJob(
            requestID: requestID,
            channel: event.channel,
            chatJID: event.chat_jid,
            sender: event.sender,
            senderName: event.sender_name,
            content: event.content,
            timestamp: event.timestamp,
            messageID: event.message_id,
            group: group,
            isScheduledTask: false,
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
            let snapshotStart = Date()
            try await writeTaskSnapshot(for: job.group)
            snapshotMs = elapsedMs(since: snapshotStart)

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
            let response = try await sessionManager.runRequest(
                group: job.group,
                payload: payload,
                timeoutMs: runtimeConfig.containerTimeoutMs
            )
            containerMs = elapsedMs(since: containerStart)
            toolCallsCount = response.tool_calls_count
            agentDurationMs = response.duration_ms

            let sessionPersistStart = Date()
            if let newSessionID = response.new_session_id, !newSessionID.isEmpty {
                try store.upsertSession(scopeKey: job.group.folder, sessionID: newSessionID)
            }
            sessionPersistMs = elapsedMs(since: sessionPersistStart)

            let ipcStart = Date()
            try await processIpcArtifacts(sourceGroup: job.group)
            ipcMs = elapsedMs(since: ipcStart)

            if job.isScheduledTask {
                try await finalizeScheduledTask(job: job, response: response, startedAt: startedAt)
                let totalMs = elapsedMs(since: startedAt)
                logger.info(
                    "Completed scheduled queue job request=\(job.requestID) group=\(job.group.folder) totalMs=\(totalMs) queueWaitMs=\(queueWaitMs) snapshotMs=\(snapshotMs ?? -1) sessionLoadMs=\(sessionLoadMs ?? -1) containerMs=\(containerMs ?? -1) sessionPersistMs=\(sessionPersistMs ?? -1) ipcMs=\(ipcMs ?? -1) toolCalls=\(toolCallsCount ?? -1) agentDurationMs=\(agentDurationMs ?? -1)"
                )
                return
            }

            let outboundStart = Date()
            if response.status == "success", let result = response.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                _ = try store.enqueueOutbound(
                    channel: job.channel,
                    chatJID: job.chatJID,
                    text: "\(assistantName): \(result)"
                )
            } else if let error = response.error {
                _ = try store.enqueueOutbound(
                    channel: job.channel,
                    chatJID: job.chatJID,
                    text: "\(assistantName): \(error)"
                )
            }
            outboundMs = elapsedMs(since: outboundStart)

            let totalMs = elapsedMs(since: startedAt)
            recordLatency(totalMs: totalMs, timedOut: isTimeoutLike(response.error))
            logger.info(
                "Completed queue job request=\(job.requestID) group=\(job.group.folder) status=success totalMs=\(totalMs) queueWaitMs=\(queueWaitMs) snapshotMs=\(snapshotMs ?? -1) sessionLoadMs=\(sessionLoadMs ?? -1) containerMs=\(containerMs ?? -1) sessionPersistMs=\(sessionPersistMs ?? -1) ipcMs=\(ipcMs ?? -1) outboundMs=\(outboundMs ?? -1) toolCalls=\(toolCallsCount ?? -1) agentDurationMs=\(agentDurationMs ?? -1)"
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
                _ = try? store.enqueueOutbound(
                    channel: job.channel,
                    chatJID: job.chatJID,
                    text: "\(assistantName): Error processing your request (\(error.localizedDescription))"
                )
            } else {
                releaseScheduledTask(job.scheduledTaskID)
            }
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

        let nextRun = nextRunISO(for: task)
        try store.updateTaskAfterRun(taskID: task.id, nextRun: nextRun, resultSummary: resultSummary)
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
                "next_run": $0.nextRun as Any
            ]
        }

        let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let fileURL = ipc.ipcRoot.appendingPathComponent("current_tasks.json")
        try json.write(to: fileURL, options: .atomic)
    }

    private func processIpcArtifacts(sourceGroup: RegisteredGroupRow) async throws {
        guard let ipc = await sessionManager.ipcPaths(for: sourceGroup.folder) else { return }
        try await processTaskIPC(in: ipc.tasksDir, sourceGroup: sourceGroup)
        try await processMessageIPC(in: ipc.messagesDir, sourceGroup: sourceGroup)
        try await writeTaskSnapshot(for: sourceGroup)
    }

    private func processMessageIPC(in directory: URL, sourceGroup: RegisteredGroupRow) async throws {
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
                logger.warning("Ignoring malformed IPC message payload: \(file.path)")
                continue
            }

            let type = stringValue(object, keys: ["type"]).lowercased()
            guard type == "send_message" || type == "message" else { continue }

            let targetJID = stringValue(object, keys: ["chat_jid", "chatJid"])
            let text = stringValue(object, keys: ["message", "text"])
            guard !targetJID.isEmpty, !text.isEmpty else { continue }

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
            _ = try store.enqueueOutbound(channel: channel, chatJID: targetJID, text: text)
        }
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

        let contextMode = nonEmptyStringValue(payload, keys: ["context_mode"]) ?? "group"
        let nextRun = nextRunISO(scheduleType: scheduleType, scheduleValue: scheduleValue)
        let taskID = nonEmptyStringValue(payload, keys: ["task_id"]) ?? "task-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"

        let row = ScheduledTaskRow(
            id: taskID,
            groupFolder: targetGroup.folder,
            chatJID: targetGroup.jid,
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
        let taskID = stringValue(payload, keys: ["task_id", "taskId"])
        guard !taskID.isEmpty else { return }
        guard let task = try store.getTask(taskID: taskID) else { return }
        let isMain = sourceGroup.folder == "main"
        guard isMain || task.groupFolder == sourceGroup.folder else {
            logger.warning("Blocked unauthorized task status mutation for \(taskID)")
            return
        }
        try store.updateTaskStatus(taskID: taskID, status: status)
    }

    private func handleCancelTaskIPC(_ payload: [String: Any], sourceGroup: RegisteredGroupRow) async throws {
        let taskID = stringValue(payload, keys: ["task_id", "taskId"])
        guard !taskID.isEmpty else { return }
        guard let task = try store.getTask(taskID: taskID) else { return }
        let isMain = sourceGroup.folder == "main"
        guard isMain || task.groupFolder == sourceGroup.folder else {
            logger.warning("Blocked unauthorized task cancellation for \(taskID)")
            return
        }
        try store.deleteTask(taskID: taskID)
        runningScheduledTaskIDs.remove(taskID)
    }

    private func schedulerLoop() async {
        while !Task.isCancelled {
            do {
                let due = try store.dueTasks(nowISO: isoNow())
                for task in due {
                    guard !runningScheduledTaskIDs.contains(task.id) else { continue }
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
                        scheduledTaskID: task.id,
                        contextMode: task.contextMode,
                        enqueuedAt: Date()
                    )
                    await queue.enqueue(job)
                }
            } catch {
                logger.error("Scheduler loop failed: \(error.localizedDescription)")
            }

            try? await Task.sleep(for: .seconds(30))
        }
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

        if let existing = workingAckTasks.removeValue(forKey: requestID) {
            existing.cancel()
        }
        workingAckTasks[requestID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: thresholdNs)
            await self?.emitWorkingAckIfPending(
                requestID: requestID,
                channel: channel,
                chatJID: chatJID
            )
        }
    }

    private func cancelWorkingAck(requestID: String) {
        guard let task = workingAckTasks.removeValue(forKey: requestID) else { return }
        task.cancel()
    }

    private func emitWorkingAckIfPending(requestID: String, channel: String, chatJID: String) async {
        guard let task = workingAckTasks.removeValue(forKey: requestID) else { return }
        if task.isCancelled || Task.isCancelled || shuttingDown {
            return
        }
        do {
            _ = try store.enqueueOutbound(
                channel: channel,
                chatJID: chatJID,
                text: "\(assistantName): Working on it, still processing your request..."
            )
            logger.info("Sent delayed working acknowledgment request=\(requestID) channel=\(channel) chat=\(chatJID)")
        } catch {
            logger.warning("Failed to enqueue delayed working acknowledgment request=\(requestID): \(error.localizedDescription)")
        }
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

    private static func parseRate(_ raw: String?, fallback: Double) -> Double {
        guard let raw, let parsed = Double(raw), parsed >= 0 else { return fallback }
        return min(parsed, 1.0)
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
        jid.hasPrefix("telegram_") ? "telegram" : "whatsapp"
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
