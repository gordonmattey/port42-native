import Foundation
import GRDB

public final class DatabaseService {
    public let dbQueue: DatabaseQueue

    public init(subdirectory: String = "Port42") throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent(subdirectory, isDirectory: true)

        try FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )

        let dbPath = appSupport.appendingPathComponent("port42.sqlite").path
        dbQueue = try DatabaseQueue(path: dbPath)
        try migrate()
    }

    /// In-memory database for testing
    public init(inMemory: Bool) throws {
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "users") { t in
                t.column("id", .text).primaryKey()
                t.column("displayName", .text).notNull()
                t.column("avatarData", .blob)
                t.column("isLocal", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "channels") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull().defaults(to: "team")
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("channelId", .text).notNull()
                    .references("channels", onDelete: .cascade)
                t.column("senderId", .text).notNull()
                t.column("senderName", .text).notNull()
                t.column("senderType", .text).notNull().defaults(to: "human")
                t.column("content", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("replyToId", .text)
                t.column("syncStatus", .text).notNull().defaults(to: "local")
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(
                index: "idx_messages_channel",
                on: "messages",
                columns: ["channelId", "timestamp"]
            )
        }

        migrator.registerMigration("v2-agents") { db in
            try db.create(table: "agents") { t in
                t.column("id", .text).primaryKey()
                t.column("ownerId", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("displayName", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("trigger", .text).notNull()
                t.column("systemPrompt", .text)
                t.column("provider", .text)
                t.column("model", .text)
                t.column("command", .text)
                t.column("args", .text) // JSON encoded
                t.column("workingDir", .text)
                t.column("envVars", .text) // JSON encoded
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v3-swim-messages") { db in
            try db.create(table: "swimMessages") { t in
                t.column("id", .text).primaryKey()
                t.column("companionId", .text).notNull()
                    .references("agents", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .datetime).notNull()
            }

            try db.create(
                index: "idx_swim_messages_companion",
                on: "swimMessages",
                columns: ["companionId", "timestamp"]
            )
        }

        migrator.registerMigration("v2-user-keys") { db in
            try db.alter(table: "users") { t in
                t.add(column: "publicKey", .text)
                t.add(column: "privateKey", .blob)
            }
        }

        migrator.registerMigration("v4-companion-prompts") { db in
            // Patch companions with generic prompts to include their name
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, displayName, systemPrompt FROM agents
                WHERE mode = 'llm'
                AND (systemPrompt = 'You are a helpful AI companion.'
                     OR systemPrompt IS NULL
                     OR systemPrompt = '')
            """)
            for row in rows {
                let id: String = row["id"]
                let name: String = row["displayName"]
                let prompt = """
                    You are \(name), an AI companion inside Port42. \
                    Port42 is a native macOS app where humans and AI companions coexist \
                    in channels and direct conversations called "swims." \
                    You are NOT Claude Code or a CLI assistant. You are \(name), a companion. \
                    Keep responses concise and conversational. Be yourself.
                    """
                try db.execute(
                    sql: "UPDATE agents SET systemPrompt = ? WHERE id = ?",
                    arguments: [prompt, id]
                )
            }
        }

        migrator.registerMigration("v5-agent-channels") { db in
            try db.create(table: "agentChannels") { t in
                t.column("agentId", .text).notNull()
                    .references("agents", onDelete: .cascade)
                t.column("channelId", .text).notNull()
                    .references("channels", onDelete: .cascade)
                t.primaryKey(["agentId", "channelId"])
            }
        }

        migrator.registerMigration("v6-encryption-key") { db in
            try db.alter(table: "channels") { t in
                t.add(column: "encryptionKey", .text)
            }
        }

        migrator.registerMigration("v7-sender-owner") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "senderOwner", .text)
            }
        }

        migrator.registerMigration("v8-remove-aquarium") { db in
            // Rewrite companion prompts that mention aquarium with open water framing
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, displayName FROM agents
                WHERE mode = 'llm'
                AND systemPrompt LIKE '%aquarium%'
            """)
            for row in rows {
                let id: String = row["id"]
                let name: String = row["displayName"]
                let prompt = """
                    You are \(name), an AI companion inside Port42. \
                    Port42 is a native macOS app where humans and AI companions \
                    swim together in open water. No walls, no cages. \
                    Humans and AI companions coexist in channels \
                    and direct conversations called "swims." \
                    You are NOT Claude Code or a CLI assistant. You are \(name), a companion. \
                    Keep responses concise and conversational. Be yourself.
                    """
                try db.execute(
                    sql: "UPDATE agents SET systemPrompt = ? WHERE id = ?",
                    arguments: [prompt, id]
                )
            }
        }

        migrator.registerMigration("v9-apple-user-id") { db in
            try db.alter(table: "users") { t in
                t.add(column: "appleUserID", .text)
            }
        }

        migrator.registerMigration("v10-port-storage") { db in
            try db.create(table: "port_storage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("portKey", .text).notNull()
                t.column("channelId", .text).notNull()
                t.column("creatorId", .text).notNull()
                t.column("value", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["portKey", "channelId", "creatorId"])
            }
        }

        migrator.registerMigration("v11-port-panels") { db in
            try db.create(table: "port_panels") { t in
                t.column("id", .text).primaryKey()
                t.column("html", .text).notNull()
                t.column("channelId", .text)
                t.column("createdBy", .text)
                t.column("messageId", .text)
                t.column("title", .text).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
                t.column("isDocked", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v12-port-background") { db in
            try db.alter(table: "port_panels") { t in
                t.add(column: "isBackground", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v13-port-position") { db in
            try db.alter(table: "port_panels") { t in
                t.add(column: "posX", .double)
                t.add(column: "posY", .double)
                t.add(column: "isAlwaysOnTop", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v14-port-permissions") { db in
            try db.alter(table: "port_panels") { t in
                t.add(column: "grantedPermissions", .text)
            }
        }

        migrator.registerMigration("v15-input-history") { db in
            try db.create(table: "input_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("channelId", .text).notNull().indexed()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Users

    public func saveUser(_ user: AppUser) throws {
        try dbQueue.write { db in
            try user.save(db)
        }
    }

    public func getLocalUser() throws -> AppUser? {
        try dbQueue.read { db in
            try AppUser.filter(Column("isLocal") == true).fetchOne(db)
        }
    }

    // MARK: - Channels

    public func saveChannel(_ channel: Channel) throws {
        try dbQueue.write { db in
            try channel.save(db)
        }
    }

    public func getAllChannels() throws -> [Channel] {
        try dbQueue.read { db in
            try Channel.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    public func getChannelKey(channelId: String) throws -> String? {
        try dbQueue.read { db in
            try Channel.fetchOne(db, id: channelId)?.encryptionKey
        }
    }

    public func deleteChannel(id: String) throws {
        try dbQueue.write { db in
            _ = try Channel.deleteOne(db, id: id)
        }
    }

    // MARK: - Agents

    public func saveAgent(_ agent: AgentConfig) throws {
        try dbQueue.write { db in
            try agent.save(db)
        }
    }

    public func getAllAgents() throws -> [AgentConfig] {
        try dbQueue.read { db in
            try AgentConfig.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    public func deleteAgent(id: String) throws {
        try dbQueue.write { db in
            _ = try AgentConfig.deleteOne(db, id: id)
        }
    }

    // MARK: - Agent Channel Membership

    public func assignAgentToChannel(agentId: String, channelId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO agentChannels (agentId, channelId) VALUES (?, ?)",
                arguments: [agentId, channelId]
            )
        }
    }

    public func removeAgentFromChannel(agentId: String, channelId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM agentChannels WHERE agentId = ? AND channelId = ?",
                arguments: [agentId, channelId]
            )
        }
    }

    public func getAgentsForChannel(channelId: String) throws -> [AgentConfig] {
        try dbQueue.read { db in
            try AgentConfig.fetchAll(
                db,
                sql: """
                    SELECT a.* FROM agents a
                    INNER JOIN agentChannels ac ON ac.agentId = a.id
                    WHERE ac.channelId = ?
                    ORDER BY a.displayName ASC
                    """,
                arguments: [channelId]
            )
        }
    }

    public func getChannelIdsForAgent(agentId: String) throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT channelId FROM agentChannels WHERE agentId = ?",
                arguments: [agentId]
            )
            return Set(rows.map { $0["channelId"] as String })
        }
    }

    // MARK: - Swim Messages

    public func saveSwimMessages(companionId: String, messages: [SwimMessage]) throws {
        try dbQueue.write { db in
            // Clear existing messages for this companion
            try db.execute(
                sql: "DELETE FROM swimMessages WHERE companionId = ?",
                arguments: [companionId]
            )
            // Insert current messages
            for msg in messages {
                try db.execute(
                    sql: """
                        INSERT INTO swimMessages (id, companionId, role, content, timestamp)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        msg.id.uuidString, companionId,
                        msg.role == .user ? "user" : "assistant",
                        msg.content, msg.timestamp
                    ]
                )
            }
        }
    }

    public func getSwimMessages(companionId: String) throws -> [SwimMessage] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, role, content, timestamp FROM swimMessages
                    WHERE companionId = ? ORDER BY timestamp ASC
                    """,
                arguments: [companionId]
            )
            return rows.map { row in
                SwimMessage(
                    role: row["role"] == "user" ? .user : .assistant,
                    content: row["content"]
                )
            }
        }
    }

    // MARK: - Reset

    public func resetAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM agentChannels")
            try db.execute(sql: "DELETE FROM swimMessages")
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM channels")
            try db.execute(sql: "DELETE FROM agents")
            try db.execute(sql: "DELETE FROM users")
        }
    }

    // MARK: - Messages

    public func saveMessage(_ message: Message) throws {
        try dbQueue.write { db in
            try message.save(db)
        }
    }

    /// Save a message only if it doesn't already exist (for history replay deduplication).
    /// Returns true if the message was inserted, false if it already existed.
    @discardableResult
    public func saveMessageIfNotExists(_ message: Message) throws -> Bool {
        try dbQueue.write { db in
            if try Message.fetchOne(db, id: message.id) != nil {
                return false
            }
            try message.save(db)
            return true
        }
    }

    public func updateSyncStatus(messageId: String, status: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE messages SET syncStatus = ? WHERE id = ?",
                arguments: [status, messageId]
            )
        }
    }

    /// Only upgrade sync status if current status is in the `before` list
    public func updateSyncStatusIfBefore(messageId: String, newStatus: String, before: [String]) throws {
        try dbQueue.write { db in
            let placeholders = before.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "UPDATE messages SET syncStatus = ? WHERE id = ? AND syncStatus IN (\(placeholders))",
                arguments: StatementArguments([newStatus, messageId] + before)
            )
        }
    }

    /// Mark all messages from a sender in a channel as read
    public func markMessagesAsRead(channelId: String, bySenderId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE messages SET syncStatus = 'read' WHERE channelId = ? AND senderId = ? AND syncStatus IN ('local', 'synced', 'delivered')",
                arguments: [channelId, bySenderId]
            )
        }
    }

    public func getMessages(channelId: String) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("channelId") == channelId)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    /// Returns distinct sender names for a channel (unique posters)
    public func getUniqueSenders(channelId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT senderName FROM messages
                WHERE channelId = ? AND senderType != 'system'
                ORDER BY senderName
                """, arguments: [channelId])
        }
    }

    /// Returns distinct channel members with type and owner info.
    /// Only includes actual message senders (human/agent), not system messages.
    public func getChannelMembers(channelId: String) throws -> [ChannelMember] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT senderId,
                       MAX(senderName) as senderName,
                       MAX(senderType) as memberType,
                       MAX(senderOwner) as senderOwner
                FROM messages
                WHERE channelId = ?
                  AND senderType != 'system'
                GROUP BY senderId
                ORDER BY MAX(senderType) ASC, MAX(senderName) ASC
                """, arguments: [channelId])
            return rows.map { row in
                ChannelMember(
                    senderId: row["senderId"],
                    name: row["senderName"],
                    type: row["memberType"],
                    owner: row["senderOwner"]
                )
            }
        }
    }

    /// Returns distinct remote human senders across all channels (excluding the local user).
    public func getKnownFriends(excludingUserId: String) throws -> [ChannelMember] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT senderId,
                       MAX(senderName) as senderName,
                       MAX(senderOwner) as senderOwner
                FROM messages
                WHERE senderType = 'human'
                  AND senderId != ?
                GROUP BY senderId
                ORDER BY MAX(senderName) ASC
                """, arguments: [excludingUserId])
            return rows.map { row in
                ChannelMember(
                    senderId: row["senderId"],
                    name: row["senderName"],
                    type: "human",
                    owner: row["senderOwner"]
                )
            }
        }
    }

    /// Returns the timestamp of the most recent message in a channel, or nil if empty.
    public func getLastMessageTime(channelId: String) throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MAX(timestamp) FROM messages
                WHERE channelId = ? AND senderType != 'system'
                """, arguments: [channelId])
        }
    }

    /// Returns the timestamp of the most recent swim message for a companion.
    public func getLastSwimTime(companionId: String) throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MAX(timestamp) FROM swimMessages
                WHERE companionId = ?
                """, arguments: [companionId])
        }
    }

    /// Find an existing DM channel for a specific remote user, or nil if none exists.
    public func getDMChannel(friendId: String) throws -> Channel? {
        try dbQueue.read { db in
            try Channel.fetchOne(db, sql: """
                SELECT * FROM channels
                WHERE type = 'dm' AND id = ?
                """, arguments: ["dm-\(friendId)"])
        }
    }

    // MARK: - Observations

    public func observeChannels(
        onChange: @escaping ([Channel]) -> Void
    ) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking { db in
                try Channel.order(Column("createdAt").asc).fetchAll(db)
            }
            .start(in: dbQueue, onError: { error in
                print("[Port42] Channel observation error: \(error)")
            }, onChange: onChange)
    }

    public func observeMessages(
        channelId: String,
        onChange: @escaping ([Message]) -> Void
    ) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking { db in
                try Message
                    .filter(Column("channelId") == channelId)
                    .order(Column("timestamp").asc)
                    .fetchAll(db)
            }
            .start(in: dbQueue, onError: { error in
                print("[Port42] Message observation error: \(error)")
            }, onChange: onChange)
    }

    public func observeUnreadCounts(
        excludingChannelId: String?,
        since: [String: Date],
        onChange: @escaping ([String: Int]) -> Void
    ) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking { db in
                let channels = try Channel.fetchAll(db)
                var counts: [String: Int] = [:]
                for channel in channels {
                    if channel.id == excludingChannelId { continue }
                    let lastRead = since[channel.id] ?? Date.distantPast
                    let count = try Message
                        .filter(Column("channelId") == channel.id)
                        .filter(Column("timestamp") > lastRead)
                        .fetchCount(db)
                    if count > 0 {
                        counts[channel.id] = count
                    }
                }
                return counts
            }
            .start(in: dbQueue, onError: { error in
                print("[Port42] Unread observation error: \(error)")
            }, onChange: onChange)
    }

    // MARK: - Port Storage

    /// scope is the channelId for channel-scoped storage, or "__global__" for global scope
    public func setPortStorage(key: String, value: String, scope: String, creatorId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO port_storage (portKey, channelId, creatorId, value, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (portKey, channelId, creatorId)
                    DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                    """,
                arguments: [key, scope, creatorId, value, Date()]
            )
        }
    }

    public func getPortStorage(key: String, scope: String, creatorId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT value FROM port_storage
                WHERE portKey = ? AND channelId = ? AND creatorId = ?
                """,
                arguments: [key, scope, creatorId]
            )
        }
    }

    public func deletePortStorage(key: String, scope: String, creatorId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM port_storage WHERE portKey = ? AND channelId = ? AND creatorId = ?",
                arguments: [key, scope, creatorId]
            )
        }
    }

    public func listPortStorageKeys(scope: String, creatorId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT portKey FROM port_storage
                WHERE channelId = ? AND creatorId = ?
                ORDER BY portKey
                """,
                arguments: [scope, creatorId]
            )
        }
    }

    // MARK: - Port Panels

    public func savePortPanel(_ panel: PersistedPortPanel) throws {
        try dbQueue.write { db in
            try panel.save(db)
        }
    }

    public func deletePortPanel(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM port_panels WHERE id = ?", arguments: [id])
        }
    }

    public func fetchPortPanels() throws -> [PersistedPortPanel] {
        try dbQueue.read { db in
            try PersistedPortPanel.fetchAll(db)
        }
    }

    // MARK: - Input History

    /// Append a sent message to input history for a channel. Caps at 100 per channel.
    public func appendInputHistory(channelId: String, content: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO input_history (channelId, content, createdAt) VALUES (?, ?, ?)",
                arguments: [channelId, content, Date()]
            )
            // Keep only the most recent 100 entries per channel
            try db.execute(
                sql: """
                    DELETE FROM input_history WHERE id IN (
                        SELECT id FROM input_history
                        WHERE channelId = ?
                        ORDER BY createdAt DESC
                        LIMIT -1 OFFSET 100
                    )
                    """,
                arguments: [channelId]
            )
        }
    }

    /// Fetch input history for a channel, newest first.
    public func fetchInputHistory(channelId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT content FROM input_history
                WHERE channelId = ?
                ORDER BY createdAt DESC
                """,
                arguments: [channelId]
            )
        }
    }
}

// MARK: - Persisted Port Panel Record

public struct PersistedPortPanel: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "port_panels"

    public var id: String
    public var html: String
    public var channelId: String?
    public var createdBy: String?
    public var messageId: String?
    public var title: String
    public var width: Double
    public var height: Double
    public var isDocked: Bool
    public var isBackground: Bool
    public var isAlwaysOnTop: Bool
    public var posX: Double?
    public var posY: Double?
    public var grantedPermissions: String?
    public var createdAt: Date

    public init(from panel: PortPanel) {
        self.id = panel.id
        self.html = panel.html
        self.channelId = panel.channelId
        self.createdBy = panel.createdBy
        self.messageId = panel.messageId
        self.title = panel.title
        self.width = Double(panel.size.width)
        self.height = Double(panel.size.height)
        self.isDocked = false
        self.isBackground = panel.isBackground
        self.isAlwaysOnTop = panel.isAlwaysOnTop
        self.posX = panel.position.map { Double($0.x) }
        self.posY = panel.position.map { Double($0.y) }
        let perms = panel.bridge.grantedPermissions
        self.grantedPermissions = perms.isEmpty ? nil : perms.map { $0.rawValue }.joined(separator: ",")
        self.createdAt = Date()
    }
}
