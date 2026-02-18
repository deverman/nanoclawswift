import Foundation

struct InboundAttachment: Codable, Sendable {
    let kind: String
    let telegramFileID: String?
    let telegramFileUniqueID: String?
    let width: Int?
    let height: Int?
    let fileSize: Int?
    let mimeType: String?
    let localPath: String?
    let ocrText: String?
}

struct InboundEventRequest: Codable, Sendable {
    let channel: String
    let chat_jid: String
    let sender: String
    let sender_name: String
    let content: String
    let timestamp: String
    let message_id: String
    let is_direct: Bool
    let attachments: [InboundAttachment]?

    init(
        channel: String,
        chat_jid: String,
        sender: String,
        sender_name: String,
        content: String,
        timestamp: String,
        message_id: String,
        is_direct: Bool,
        attachments: [InboundAttachment]? = nil
    ) {
        self.channel = channel
        self.chat_jid = chat_jid
        self.sender = sender
        self.sender_name = sender_name
        self.content = content
        self.timestamp = timestamp
        self.message_id = message_id
        self.is_direct = is_direct
        self.attachments = attachments
    }
}

struct InboundEventResponse: Codable, Sendable {
    let accepted: Bool
    let group_folder: String?
    let request_id: String?
}

struct OutboundClaimRequest: Codable, Sendable {
    let channel: String
    let max_count: Int?
}

struct OutboundMessageDTO: Codable, Sendable {
    let id: String
    let chat_jid: String
    let text: String
    let kind: String?
    let attachment_path: String?
    let caption: String?
    let created_at: String
}

struct OutboundClaimResponse: Codable, Sendable {
    let messages: [OutboundMessageDTO]
}

struct OutboundAckRequest: Codable, Sendable {
    let message_ids: [String]
}

struct OutboundAckResponse: Codable, Sendable {
    let acked_count: Int
}

struct HealthResponse: Codable, Sendable {
    let ok: Bool
    let active_group_sessions: Int
    let queue_depth: Int
    let db_status: String
    let response_p50_ms: Int?
    let response_p95_ms: Int?
    let timeout_rate: Double?
    let retry_rate: Double?
    let completed_jobs: Int?
}

struct RegisteredGroupRow: Sendable {
    let jid: String
    let name: String
    let folder: String
    let triggerPattern: String
    let addedAt: String
    let containerConfigJSON: String?
    let requiresTrigger: Bool
}

struct SessionRow: Sendable {
    let scopeKey: String
    let sessionID: String
    let updatedAt: String
}

struct OutboundMessageRow: Sendable {
    let id: String
    let channel: String
    let chatJID: String
    let text: String
    let kind: String
    let attachmentPath: String?
    let caption: String?
    let status: String
    let createdAt: String
    let sentAt: String?
}

struct ScheduledTaskRow: Sendable {
    let id: String
    let groupFolder: String
    let chatJID: String
    let prompt: String
    let scheduleType: String
    let scheduleValue: String
    let contextMode: String
    let nextRun: String?
    let status: String
    let createdAt: String
}

struct TaskRunLogRow: Sendable {
    let taskID: String
    let runAt: String
    let durationMs: Int
    let status: String
    let result: String?
    let error: String?
}

struct ContainerRequestPayload: Codable, Sendable {
    let request_id: String
    let prompt: String
    let session_id: String?
    let chat_jid: String
    let group_folder: String
    let is_main: Bool
    let is_scheduled_task: Bool
}

struct ContainerResponsePayload: Codable, Sendable {
    let request_id: String
    let status: String
    let result: String?
    let new_session_id: String?
    let error: String?
    let tool_calls_count: Int?
    let duration_ms: Int?
}

struct QueueJob: Sendable {
    let requestID: String
    let channel: String
    let chatJID: String
    let sender: String
    let senderName: String
    let content: String
    let timestamp: String
    let messageID: String
    let group: RegisteredGroupRow
    let isScheduledTask: Bool
    let isStartupCatchUp: Bool
    let scheduledTaskID: String?
    let contextMode: String
    let enqueuedAt: Date
}
