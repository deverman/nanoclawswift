import Foundation
import GRDB
import Logging

enum SQLiteStoreError: Error, CustomStringConvertible {
    case invalidData(message: String)

    var description: String {
        switch self {
        case let .invalidData(message):
            return "Invalid persisted data: \(message)"
        }
    }
}

private struct LegacyRegisteredGroup: Codable {
    let name: String
    let folder: String
    let trigger: String?
    let added_at: String?
    let containerConfig: [String: AnyCodable]?
}

/// Minimal codable wrapper for unknown JSON values in legacy files.
private struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
            return
        }
        if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
            return
        }
        if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
            return
        }
        if let stringValue = try? container.decode(String.self) {
            value = stringValue
            return
        }
        if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map(\.value)
            return
        }
        if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues(\.value)
            return
        }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let arrayValue as [Any]:
            try container.encode(arrayValue.map(AnyCodable.init))
        case let dictValue as [String: Any]:
            try container.encode(dictValue.mapValues(AnyCodable.init))
        default:
            try container.encodeNil()
        }
    }
}

final class SQLiteStore {
    private let logger: Logger
    private let dbPath: String
    private let dbQueue: DatabaseQueue
    private let formatter = ISO8601DateFormatter()
    private let outboundClaimLeaseSeconds: TimeInterval = 90

    init(dbPath: String, dataDir: String, logger: Logger) throws {
        self.logger = logger
        self.dbPath = dbPath

        let directory = URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: dbPath, configuration: config)

        try createSchema()
        try migrateFromLegacyJSONIfNeeded(dataDir: dataDir)
    }

    func isHealthy() -> Bool {
        do {
            _ = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT 1;")
            }
            return true
        } catch {
            logger.error("SQLite health check failed: \(error.localizedDescription)")
            return false
        }
    }

    func fetchGroup(jid: String) throws -> RegisteredGroupRow? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT jid, name, folder, trigger_pattern, added_at, container_config, requires_trigger
                FROM registered_groups
                WHERE jid = ?;
                """,
                arguments: [jid]
            ) else {
                return nil
            }
            return mapRegisteredGroup(row)
        }
    }

    func findGroup(folder: String) throws -> RegisteredGroupRow? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT jid, name, folder, trigger_pattern, added_at, container_config, requires_trigger
                FROM registered_groups
                WHERE folder = ?
                ORDER BY added_at DESC
                LIMIT 1;
                """,
                arguments: [folder]
            ) else {
                return nil
            }
            return mapRegisteredGroup(row)
        }
    }

    func listGroups(limit: Int? = nil) throws -> [RegisteredGroupRow] {
        try dbQueue.read { db in
            let rows: [Row]
            if let limit, limit > 0 {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT jid, name, folder, trigger_pattern, added_at, container_config, requires_trigger
                    FROM registered_groups
                    ORDER BY requires_trigger ASC, added_at DESC
                    LIMIT ?;
                    """,
                    arguments: [limit]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT jid, name, folder, trigger_pattern, added_at, container_config, requires_trigger
                    FROM registered_groups
                    ORDER BY requires_trigger ASC, added_at DESC;
                    """
                )
            }
            return rows.map(mapRegisteredGroup)
        }
    }

    func upsertGroup(_ group: RegisteredGroupRow) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO registered_groups (
                  jid, name, folder, trigger_pattern, added_at, container_config, requires_trigger
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(jid) DO UPDATE SET
                  name = excluded.name,
                  folder = excluded.folder,
                  trigger_pattern = excluded.trigger_pattern,
                  added_at = excluded.added_at,
                  container_config = excluded.container_config,
                  requires_trigger = excluded.requires_trigger;
                """,
                arguments: [
                    group.jid,
                    group.name,
                    group.folder,
                    group.triggerPattern,
                    group.addedAt,
                    group.containerConfigJSON,
                    group.requiresTrigger ? 1 : 0
                ]
            )
        }
    }

    func getSession(scopeKey: String) throws -> SessionRow? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT scope_key, session_id, updated_at
                FROM sessions
                WHERE scope_key = ?;
                """,
                arguments: [scopeKey]
            ) else {
                return nil
            }
            return mapSession(row)
        }
    }

    func upsertSession(scopeKey: String, sessionID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions(scope_key, session_id, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(scope_key) DO UPDATE SET
                  session_id = excluded.session_id,
                  updated_at = excluded.updated_at;
                """,
                arguments: [scopeKey, sessionID, isoNow()]
            )
        }
    }

    func enqueueOutbound(channel: String, chatJID: String, text: String) throws -> String {
        let messageID = "out-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO outbound_messages(id, channel, chat_jid, text, status, created_at)
                VALUES (?, ?, ?, ?, 'pending', ?);
                """,
                arguments: [messageID, channel, chatJID, text, isoNow()]
            )
        }
        return messageID
    }

    func claimOutbound(channel: String, maxCount: Int) throws -> [OutboundMessageRow] {
        let clampedMax = max(1, min(maxCount, 50))
        return try dbQueue.write { db in
            // Recover stale claims so transient adapter failures don't strand messages forever.
            let reclaimBefore = isoDate(offsetSeconds: -outboundClaimLeaseSeconds)
            try db.execute(
                sql: """
                UPDATE outbound_messages
                SET status = 'pending', sent_at = NULL
                WHERE channel = ? AND status = 'claimed' AND sent_at IS NOT NULL AND sent_at <= ?;
                """,
                arguments: [channel, reclaimBefore]
            )

            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, channel, chat_jid, text, status, created_at, sent_at
                FROM outbound_messages
                WHERE channel = ? AND status = 'pending'
                ORDER BY created_at
                LIMIT ?;
                """,
                arguments: [channel, clampedMax]
            )
            if rows.isEmpty {
                return []
            }

            let now = isoNow()
            for row in rows {
                let id: String = row["id"]
                try db.execute(
                    sql: """
                    UPDATE outbound_messages
                    SET status = 'claimed', sent_at = ?
                    WHERE id = ? AND status = 'pending';
                    """,
                    arguments: [now, id]
                )
            }

            return rows.map(mapOutboundMessage)
        }
    }

    func ackOutbound(messageIDs: [String]) throws -> Int {
        guard !messageIDs.isEmpty else { return 0 }
        return try dbQueue.write { db in
            var acked = 0
            for messageID in messageIDs {
                try db.execute(
                    sql: """
                    UPDATE outbound_messages
                    SET status = 'acked'
                    WHERE id = ? AND status = 'claimed';
                    """,
                    arguments: [messageID]
                )
                acked += Int(db.changesCount)
            }
            return acked
        }
    }

    func tryInsertInboundEvent(channel: String, chatJID: String, messageID: String) throws -> Bool {
        guard !channel.isEmpty, !chatJID.isEmpty, !messageID.isEmpty else {
            return false
        }
        return try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO inbound_events(channel, chat_jid, message_id, received_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(channel, chat_jid, message_id) DO NOTHING;
                """,
                arguments: [channel, chatJID, messageID, isoNow()]
            )
            return db.changesCount > 0
        }
    }

    func listTasks(for groupFolder: String?, includeAll: Bool) throws -> [ScheduledTaskRow] {
        try dbQueue.read { db in
            let rows: [Row]
            if includeAll {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, group_folder, chat_jid, prompt, schedule_type, schedule_value,
                           COALESCE(context_mode, 'isolated') AS context_mode,
                           next_run, status, created_at
                    FROM scheduled_tasks
                    ORDER BY created_at DESC;
                    """
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, group_folder, chat_jid, prompt, schedule_type, schedule_value,
                           COALESCE(context_mode, 'isolated') AS context_mode,
                           next_run, status, created_at
                    FROM scheduled_tasks
                    WHERE group_folder = ?
                    ORDER BY created_at DESC;
                    """,
                    arguments: [groupFolder ?? ""]
                )
            }
            return rows.map(mapScheduledTask)
        }
    }

    func getTask(taskID: String) throws -> ScheduledTaskRow? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, group_folder, chat_jid, prompt, schedule_type, schedule_value,
                       COALESCE(context_mode, 'isolated') AS context_mode,
                       next_run, status, created_at
                FROM scheduled_tasks
                WHERE id = ?;
                """,
                arguments: [taskID]
            ) else {
                return nil
            }
            return mapScheduledTask(row)
        }
    }

    func createTask(_ task: ScheduledTaskRow) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO scheduled_tasks (
                  id, group_folder, chat_jid, prompt, schedule_type, schedule_value,
                  context_mode, next_run, status, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                arguments: [
                    task.id,
                    task.groupFolder,
                    task.chatJID,
                    task.prompt,
                    task.scheduleType,
                    task.scheduleValue,
                    task.contextMode,
                    task.nextRun,
                    task.status,
                    task.createdAt
                ]
            )
        }
    }

    func updateTaskStatus(taskID: String, status: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE scheduled_tasks SET status = ? WHERE id = ?;",
                arguments: [status, taskID]
            )
        }
    }

    func deleteTask(taskID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM task_run_logs WHERE task_id = ?;",
                arguments: [taskID]
            )
            try db.execute(
                sql: "DELETE FROM scheduled_tasks WHERE id = ?;",
                arguments: [taskID]
            )
        }
    }

    func dueTasks(nowISO: String) throws -> [ScheduledTaskRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, group_folder, chat_jid, prompt, schedule_type, schedule_value,
                       COALESCE(context_mode, 'isolated') AS context_mode,
                       next_run, status, created_at
                FROM scheduled_tasks
                WHERE status = 'active' AND next_run IS NOT NULL AND next_run <= ?
                ORDER BY next_run ASC;
                """,
                arguments: [nowISO]
            )
            return rows.map(mapScheduledTask)
        }
    }

    func updateTaskAfterRun(taskID: String, nextRun: String?, resultSummary: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE scheduled_tasks
                SET next_run = ?,
                    last_run = ?,
                    last_result = ?,
                    status = CASE WHEN ? IS NULL THEN 'completed' ELSE status END
                WHERE id = ?;
                """,
                arguments: [nextRun, isoNow(), resultSummary, nextRun, taskID]
            )
        }
    }

    func logTaskRun(_ log: TaskRunLogRow) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO task_run_logs(task_id, run_at, duration_ms, status, result, error)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                arguments: [log.taskID, log.runAt, log.durationMs, log.status, log.result, log.error]
            )
        }
    }

    // MARK: - Private

    private func createSchema() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS router_state (
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS sessions (
                  scope_key TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS registered_groups (
                  jid TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  folder TEXT NOT NULL,
                  trigger_pattern TEXT NOT NULL,
                  added_at TEXT NOT NULL,
                  container_config TEXT,
                  requires_trigger INTEGER NOT NULL DEFAULT 1
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS outbound_messages (
                  id TEXT PRIMARY KEY,
                  channel TEXT NOT NULL,
                  chat_jid TEXT NOT NULL,
                  text TEXT NOT NULL,
                  status TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  sent_at TEXT
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS inbound_events (
                  channel TEXT NOT NULL,
                  chat_jid TEXT NOT NULL,
                  message_id TEXT NOT NULL,
                  received_at TEXT NOT NULL,
                  PRIMARY KEY(channel, chat_jid, message_id)
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS scheduled_tasks (
                  id TEXT PRIMARY KEY,
                  group_folder TEXT NOT NULL,
                  chat_jid TEXT NOT NULL,
                  prompt TEXT NOT NULL,
                  schedule_type TEXT NOT NULL,
                  schedule_value TEXT NOT NULL,
                  context_mode TEXT DEFAULT 'isolated',
                  next_run TEXT,
                  last_run TEXT,
                  last_result TEXT,
                  status TEXT DEFAULT 'active',
                  created_at TEXT NOT NULL
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS task_run_logs (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  task_id TEXT NOT NULL,
                  run_at TEXT NOT NULL,
                  duration_ms INTEGER NOT NULL,
                  status TEXT NOT NULL,
                  result TEXT,
                  error TEXT,
                  FOREIGN KEY (task_id) REFERENCES scheduled_tasks(id)
                );
                """
            )
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_outbound_status ON outbound_messages(channel, status, created_at);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_inbound_received_at ON inbound_events(received_at);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_next_run ON scheduled_tasks(next_run);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_status ON scheduled_tasks(status);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_task_run_logs ON task_run_logs(task_id, run_at);")

            // Existing stores may have scheduled_tasks without context_mode.
            try? db.execute(sql: "ALTER TABLE scheduled_tasks ADD COLUMN context_mode TEXT DEFAULT 'isolated';")
        }
    }

    private func migrateFromLegacyJSONIfNeeded(dataDir: String) throws {
        let sessionsCount = try scalarInt("SELECT COUNT(*) FROM sessions;")
        if sessionsCount == 0 {
            try migrateLegacySessions(dataDir: dataDir)
        }

        let groupsCount = try scalarInt("SELECT COUNT(*) FROM registered_groups;")
        if groupsCount == 0 {
            try migrateLegacyGroups(dataDir: dataDir)
        }

        let routerCount = try scalarInt("SELECT COUNT(*) FROM router_state;")
        if routerCount == 0 {
            try migrateLegacyRouterState(dataDir: dataDir)
        }
    }

    private func migrateLegacySessions(dataDir: String) throws {
        let path = URL(fileURLWithPath: dataDir).appendingPathComponent("sessions.json").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        for (scopeKey, sessionID) in decoded where !sessionID.isEmpty {
            try upsertSession(scopeKey: scopeKey, sessionID: sessionID)
        }
        logger.info("Migrated \(decoded.count) legacy sessions from JSON")
    }

    private func migrateLegacyGroups(dataDir: String) throws {
        let path = URL(fileURLWithPath: dataDir).appendingPathComponent("registered_groups.json").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode([String: LegacyRegisteredGroup].self, from: data)
        for (jid, group) in decoded {
            let containerJSON: String?
            if let containerConfig = group.containerConfig {
                let plain = containerConfig.mapValues(\.value)
                let encoded = try JSONSerialization.data(withJSONObject: plain, options: [.sortedKeys])
                containerJSON = String(data: encoded, encoding: .utf8)
            } else {
                containerJSON = nil
            }

            let row = RegisteredGroupRow(
                jid: jid,
                name: group.name,
                folder: group.folder,
                triggerPattern: group.trigger ?? "@Andy",
                addedAt: group.added_at ?? isoNow(),
                containerConfigJSON: containerJSON,
                requiresTrigger: true
            )
            try upsertGroup(row)
        }
        logger.info("Migrated \(decoded.count) legacy groups from JSON")
    }

    private func migrateLegacyRouterState(dataDir: String) throws {
        let path = URL(fileURLWithPath: dataDir).appendingPathComponent("router_state.json").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = raw as? [String: Any] else { return }
        for (key, value) in dict {
            let serialized: String
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: []),
               let text = String(data: data, encoding: .utf8) {
                serialized = text
            } else {
                serialized = String(describing: value)
            }
            try upsertRouterState(key: key, value: serialized)
        }
        logger.info("Migrated legacy router_state.json to SQLite")
    }

    private func upsertRouterState(key: String, value: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO router_state(key, value)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """,
                arguments: [key, value]
            )
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try dbQueue.read { db in
            guard let value = try Int.fetchOne(db, sql: sql) else {
                return 0
            }
            return value
        }
    }

    private func mapRegisteredGroup(_ row: Row) -> RegisteredGroupRow {
        let jid: String = row["jid"]
        let name: String = row["name"]
        let folder: String = row["folder"]
        let triggerPattern: String = row["trigger_pattern"]
        let addedAt: String = row["added_at"]
        let containerConfigJSON: String? = row["container_config"]
        let requiresTriggerInt: Int64 = row["requires_trigger"]
        return RegisteredGroupRow(
            jid: jid,
            name: name,
            folder: folder,
            triggerPattern: triggerPattern,
            addedAt: addedAt,
            containerConfigJSON: containerConfigJSON,
            requiresTrigger: requiresTriggerInt == 1
        )
    }

    private func mapSession(_ row: Row) -> SessionRow {
        let scopeKey: String = row["scope_key"]
        let sessionID: String = row["session_id"]
        let updatedAt: String = row["updated_at"]
        return SessionRow(scopeKey: scopeKey, sessionID: sessionID, updatedAt: updatedAt)
    }

    private func mapOutboundMessage(_ row: Row) -> OutboundMessageRow {
        let id: String = row["id"]
        let channel: String = row["channel"]
        let chatJID: String = row["chat_jid"]
        let text: String = row["text"]
        let status: String = row["status"]
        let createdAt: String = row["created_at"]
        let sentAt: String? = row["sent_at"]
        return OutboundMessageRow(
            id: id,
            channel: channel,
            chatJID: chatJID,
            text: text,
            status: status,
            createdAt: createdAt,
            sentAt: sentAt
        )
    }

    private func mapScheduledTask(_ row: Row) -> ScheduledTaskRow {
        let id: String = row["id"]
        let groupFolder: String = row["group_folder"]
        let chatJID: String = row["chat_jid"]
        let prompt: String = row["prompt"]
        let scheduleType: String = row["schedule_type"]
        let scheduleValue: String = row["schedule_value"]
        let contextMode: String = row["context_mode"]
        let nextRun: String? = row["next_run"]
        let status: String = row["status"]
        let createdAt: String = row["created_at"]
        return ScheduledTaskRow(
            id: id,
            groupFolder: groupFolder,
            chatJID: chatJID,
            prompt: prompt,
            scheduleType: scheduleType,
            scheduleValue: scheduleValue,
            contextMode: contextMode,
            nextRun: nextRun,
            status: status,
            createdAt: createdAt
        )
    }

    private func isoNow() -> String {
        formatter.string(from: Date())
    }

    private func isoDate(offsetSeconds: TimeInterval) -> String {
        formatter.string(from: Date().addingTimeInterval(offsetSeconds))
    }
}
