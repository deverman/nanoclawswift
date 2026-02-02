import SwiftAgents
import Foundation

// MARK: - FileBasedSession

/// File-based session implementation that persists conversation history to JSON files.
///
/// `FileBasedSession` stores conversation history in the group folder's `.nanoclaw/session.json` file,
/// enabling conversation persistence across agent restarts. File permissions are set to 600 (owner read/write only)
/// for security.
///
/// This implementation is ideal for:
/// - Persistent conversations across agent restarts
/// - Multi-turn conversations with history
/// - Secure storage with restricted file permissions
///
/// ## Thread Safety
/// As an actor, `FileBasedSession` provides automatic thread-safe access
/// to all session data through Swift's actor isolation.
///
/// ## Example Usage
/// ```swift
/// // Create with group folder path
/// let session = FileBasedSession(groupFolder: "my-group")
///
/// // Add conversation messages
/// try await session.addItem(.user("What's the weather?"))
/// try await session.addItem(.assistant("It's sunny today!"))
///
/// // Retrieve recent history
/// let recent = try await session.getItems(limit: 10)
/// ```
public actor FileBasedSession: Session {
    // MARK: Public
    
    /// Unique identifier for this session.
    nonisolated public let sessionId: String
    
    /// Path to the session file.
    nonisolated public let sessionFilePath: String
    
    // MARK: - Session Protocol Properties
    
    /// Number of items currently stored in the session.
    public var itemCount: Int {
        items.count
    }
    
    /// Whether the session contains no items.
    public var isEmpty: Bool {
        items.isEmpty
    }
    
    // MARK: - Initialization
    
    /// Creates a new file-based session for the given group folder.
    ///
    /// - Parameters:
    ///   - groupFolder: The group folder name (e.g., "my-group")
    ///   - sessionId: Unique identifier for the session (defaults to "default")
    ///
    /// The session file is stored at `/workspace/group/{groupFolder}/.nanoclaw/session.json`
    public init(groupFolder: String, sessionId: String = "default") {
        self.sessionId = sessionId
        let groupPath = "/workspace/group/\(groupFolder)"
        self.sessionFilePath = "\(groupPath)/.nanoclaw/session.json"
        
        // Ensure directory exists
        Task {
            await ensureDirectoryExists()
        }
    }
    
    /// Creates a new file-based session with a custom file path.
    ///
    /// - Parameters:
    ///   - sessionId: Unique identifier for the session
    ///   - filePath: Full path to the session JSON file
    public init(sessionId: String = UUID().uuidString, filePath: String) {
        self.sessionId = sessionId
        self.sessionFilePath = filePath
        
        // Ensure directory exists
        Task {
            await ensureDirectoryExists()
        }
    }
    
    /// Retrieves the item count with proper error propagation.
    ///
    /// - Returns: The number of items in the session.
    /// - Throws: `SessionError.retrievalFailed` if reading fails.
    public func getItemCount() async throws -> Int {
        try await loadItems()
        return items.count
    }
    
    // MARK: - Session Protocol Methods
    
    /// Retrieves conversation history from the session.
    ///
    /// Items are returned in chronological order (oldest first).
    /// When a limit is specified, returns the most recent N items
    /// while still maintaining chronological order.
    ///
    /// - Parameter limit: Maximum number of items to retrieve.
    ///   - `nil`: Returns all items
    ///   - Positive value: Returns the last N items in chronological order
    ///   - Zero or negative: Returns an empty array
    /// - Returns: Array of messages in chronological order.
    /// - Throws: `SessionError.retrievalFailed` if reading fails.
    public func getItems(limit: Int?) async throws -> [MemoryMessage] {
        try await loadItems()
        
        guard let limit else {
            return items
        }
        
        guard limit > 0 else {
            return []
        }
        
        // Return last N items in chronological order
        let startIndex = max(0, items.count - limit)
        return Array(items[startIndex...])
    }
    
    /// Adds items to the conversation history.
    ///
    /// Items are appended in the order they appear in the array,
    /// maintaining the conversation's chronological sequence.
    /// Automatically persists to the file system with restricted permissions.
    ///
    /// - Parameter newItems: Messages to add to the session.
    /// - Throws: `SessionError.storageFailed` if saving fails.
    public func addItems(_ newItems: [MemoryMessage]) async throws {
        try await loadItems()
        items.append(contentsOf: newItems)
        try await saveItems()
    }
    
    /// Removes and returns the most recent item from the session.
    ///
    /// Follows LIFO (Last-In-First-Out) semantics.
    ///
    /// - Returns: The removed message, or `nil` if the session is empty.
    /// - Throws: `SessionError.storageFailed` if saving fails.
    public func popItem() async throws -> MemoryMessage? {
        try await loadItems()
        
        guard !items.isEmpty else {
            return nil
        }
        
        let item = items.removeLast()
        try await saveItems()
        return item
    }
    
    /// Clears all items from this session.
    ///
    /// The session ID remains unchanged, allowing the session to be
    /// reused for new conversations.
    ///
    /// - Throws: `SessionError.deletionFailed` if clearing fails.
    public func clearSession() async throws {
        items.removeAll()
        try await saveItems()
    }
    
    // MARK: Private
    
    /// Internal storage for messages (in-memory cache).
    private var items: [MemoryMessage] = []
    
    /// File manager for operations.
    private let fileManager = FileManager.default
    
    /// Loads items from the file system if not already in memory.
    private func loadItems() async throws {
        let path = sessionFilePath
        
        guard fileManager.fileExists(atPath: path) else {
            items = []
            return
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let storedItems = try decoder.decode([StoredMessage].self, from: data)
            items = storedItems.map { $0.toMemoryMessage() }
        } catch {
            throw SessionError.retrievalFailed(
                reason: "Failed to load session from \(path)",
                underlyingError: error.localizedDescription
            )
        }
    }
    
    /// Saves items to the file system with restricted permissions (600).
    private func saveItems() async throws {
        do {
            // Ensure directory exists
            await ensureDirectoryExists()
            
            // Convert to storage format
            let storedItems = items.map { StoredMessage(from: $0) }
            
            // Encode to JSON
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(storedItems)
            
            // Write to temporary file first, then move (atomic operation)
            let tempPath = sessionFilePath + ".tmp"
            try data.write(to: URL(fileURLWithPath: tempPath))
            
            // Move temp file to final location
            if fileManager.fileExists(atPath: sessionFilePath) {
                try fileManager.removeItem(atPath: sessionFilePath)
            }
            try fileManager.moveItem(atPath: tempPath, toPath: sessionFilePath)
            
            // Set restrictive permissions (owner read/write only)
            try setSecurePermissions(path: sessionFilePath)
            
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError.storageFailed(
                reason: "Failed to save session to \(sessionFilePath)",
                underlyingError: error.localizedDescription
            )
        }
    }
    
    /// Ensures the session directory exists.
    private func ensureDirectoryExists() async {
        let dirPath = (sessionFilePath as NSString).deletingLastPathComponent
        
        if !fileManager.fileExists(atPath: dirPath) {
            do {
                try fileManager.createDirectory(
                    atPath: dirPath,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                // Directory creation failed, but we'll handle it when saving
            }
        }
    }
    
    /// Sets file permissions to 600 (owner read/write only).
    private func setSecurePermissions(path: String) throws {
        #if os(macOS) || os(Linux)
        // Set permissions to 600 (owner read/write, no other permissions)
        let permissions: mode_t = 0o600
        let result = chmod(path, permissions)
        
        if result != 0 {
            throw SessionError.storageFailed(
                reason: "Failed to set file permissions on \(path)",
                underlyingError: String(cString: strerror(errno))
            )
        }
        #endif
    }
}

// MARK: - StoredMessage

/// Internal storage format for messages in the session file.
private struct StoredMessage: Codable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date
    let metadata: [String: String]
    
    init(from message: MemoryMessage) {
        self.id = message.id
        self.role = message.role.rawValue
        self.content = message.content
        self.timestamp = message.timestamp
        self.metadata = message.metadata
    }
    
    func toMemoryMessage() -> MemoryMessage {
        MemoryMessage(
            id: id,
            role: MemoryMessage.Role(rawValue: role) ?? .user,
            content: content,
            timestamp: timestamp,
            metadata: metadata
        )
    }
}
