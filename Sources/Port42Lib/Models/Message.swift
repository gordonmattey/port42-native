import Foundation
import GRDB

public struct Message: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "messages"

    public var id: String
    public var spaceId: String
    public var senderId: String
    public var senderName: String
    public var senderType: String
    public var senderOwner: String?
    public var content: String
    public var timestamp: Date
    public var replyToId: String?
    public var syncStatus: String
    public var createdAt: Date
    public var topic: String

    public init(
        id: String, spaceId: String, senderId: String, senderName: String,
        senderType: String, content: String, timestamp: Date,
        replyToId: String?, syncStatus: String, createdAt: Date,
        senderOwner: String? = nil, topic: String = "chat"
    ) {
        self.id = id
        self.spaceId = spaceId
        self.senderId = senderId
        self.senderName = senderName
        self.senderType = senderType
        self.senderOwner = senderOwner
        self.content = content
        self.timestamp = timestamp
        self.replyToId = replyToId
        self.syncStatus = syncStatus
        self.createdAt = createdAt
        self.topic = topic
    }

    public static func create(
        spaceId: String,
        senderId: String,
        senderName: String,
        content: String,
        senderType: String = "human",
        senderOwner: String? = nil,
        topic: String = "chat"
    ) -> Message {
        let now = Date()
        // Humans own themselves, agents have an explicit owner
        let owner = senderOwner ?? (senderType == "human" ? senderName : nil)
        return Message(
            id: UUID().uuidString,
            spaceId: spaceId,
            senderId: senderId,
            senderName: senderName,
            senderType: senderType,
            content: content,
            timestamp: now,
            replyToId: nil,
            syncStatus: "local",
            createdAt: now,
            senderOwner: owner,
            topic: topic
        )
    }

    public var isAgent: Bool { senderType == "agent" }
    public var isSystem: Bool { senderType == "system" }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: timestamp)
    }
}
