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
    /// Whether this space participates in WebSocket sync. False for direct (DM) spaces.
    public var syncEnabled: Bool
    /// Heartbeat interval in minutes. 0 = off. Fires a prompt to wake up companions.
    public var heartbeatInterval: Int
    /// The prompt sent to companions on each heartbeat tick.
    public var heartbeatPrompt: String
    /// SHELL S3 — per-space accent as a hex string, assigned at creation and kept for life so a
    /// space never loses its color when others are added/deleted. Nil for spaces predating this /
    /// remote spaces → `ShellState.accent(for:)` falls back to a stable id-hash.
    public var accent: String?
    /// Rest/Wake (the working set): nil = working (galaxy front, ⌘1–9, peeks live); a timestamp =
    /// at rest (off the front, no index, fully silent — sync continues underneath). A timestamp
    /// rather than a bool so the galaxy shelf can sort by recency of resting.
    public var restedAt: Date?

    public init(id: String, name: String, type: String, createdAt: Date, encryptionKey: String? = nil, syncEnabled: Bool = true, heartbeatInterval: Int = 0, heartbeatPrompt: String = "", accent: String? = nil, restedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.createdAt = createdAt
        self.encryptionKey = encryptionKey
        self.syncEnabled = syncEnabled
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatPrompt = heartbeatPrompt
        self.accent = accent
        self.restedAt = restedAt
    }

    /// A rested space is alive-but-dormant: nothing is lost, it just can't reach for attention.
    public var isResting: Bool { restedAt != nil }

    public static func create(name: String, type: String = "team") -> Space {
        Space(
            id: UUID().uuidString,
            name: name,
            type: type,
            createdAt: Date(),
            encryptionKey: SpaceCrypto.generateKey()
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
