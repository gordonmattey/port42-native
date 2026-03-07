import Foundation
import GRDB

public final class DatabaseService {
    public let dbQueue: DatabaseQueue

    public init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Port42", isDirectory: true)

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

    public func getMessages(channelId: String) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("channelId") == channelId)
                .order(Column("timestamp").asc)
                .fetchAll(db)
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
}
