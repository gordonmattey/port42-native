import Foundation
import GRDB

public struct Space: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "spaces"

    public var id: String
    public var name: String
    public var type: String
    public var createdAt: Date
    /// Base64-encoded AES-256-GCM symmetric key for E2E encryption.
    /// Nil for spaces created before encryption was added.
    public var encryptionKey: String?
    /// Whether this space participates in WebSocket sync. False for swim spaces.
    public var syncEnabled: Bool
    /// Whether this is a swim space (1:1 with a companion, not synced).
    public var isSwim: Bool
    /// Heartbeat interval in minutes. 0 = off. Fires a prompt to wake up companions.
    public var heartbeatInterval: Int
    /// The prompt sent to companions on each heartbeat tick.
    public var heartbeatPrompt: String

    public init(id: String, name: String, type: String, createdAt: Date, encryptionKey: String? = nil, syncEnabled: Bool = true, isSwim: Bool = false, heartbeatInterval: Int = 0, heartbeatPrompt: String = "") {
        self.id = id
        self.name = name
        self.type = type
        self.createdAt = createdAt
        self.encryptionKey = encryptionKey
        self.syncEnabled = syncEnabled
        self.isSwim = isSwim
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatPrompt = heartbeatPrompt
    }

    public static func create(name: String, type: String = "team") -> Space {
        Space(
            id: UUID().uuidString,
            name: name,
            type: type,
            createdAt: Date(),
            encryptionKey: SpaceCrypto.generateKey()
        )
    }

    public static func swim(companion: AgentConfig) -> Space {
        Space(
            id: "swim-\(companion.id)",
            name: companion.displayName,
            type: "direct",
            createdAt: Date(),
            encryptionKey: nil,
            syncEnabled: false,
            isSwim: true
        )
    }
}

/// A space participant derived from message history
public struct SpaceMember: Identifiable, Equatable {
    public let senderId: String
    public let name: String
    public let type: String   // "human" or "agent"
    public let owner: String? // owner's display name (nil for humans)

    public var id: String { senderId }

    /// Full namespaced identity (always includes owner when available)
    public var qualifiedName: String {
        if let owner {
            return "\(name)@\(owner)"
        }
        return name
    }

    /// Display name for UI. Strips namespace for local entities.
    public func displayName(localOwner: String? = nil) -> String {
        if let owner, owner.lowercased() != localOwner?.lowercased(),
           owner.lowercased() != name.lowercased() {
            return "\(name)@\(owner)"
        }
        return name
    }

    public var isAgent: Bool { type == "agent" }
}
