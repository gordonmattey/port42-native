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
    /// User-picked working directory for command companions (docs/plan-companion-cwd.md). A
    /// `.command` companion spawned in this space defaults its cwd here so companions share one
    /// workspace (and each gets its own claude session id for isolation). Nil = fall back to home
    /// (the resolver in `resolveTerminalCwd`); nil for spaces predating this field / remote spaces.
    public var workingDirectory: String?
    /// Drag-reorder position (backlog 3.6): this space's persistent slot in the galaxy front and
    /// ⌘1–9, distinct from the ⌘K recency axis (0.6). Backfilled from creation order by migration v42;
    /// a new space lands at the end (`nextSortIndex`, assigned in `AppState.createSpace`).
    public var sortIndex: Int = 0

    public init(id: String, name: String, type: String, createdAt: Date, encryptionKey: String? = nil, syncEnabled: Bool = true, heartbeatInterval: Int = 0, heartbeatPrompt: String = "", accent: String? = nil, restedAt: Date? = nil, workingDirectory: String? = nil, sortIndex: Int = 0) {
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
        self.workingDirectory = workingDirectory
        self.sortIndex = sortIndex
    }

    /// The sortIndex a newly created space should get: one past the current maximum, so it lands at
    /// the end of the galaxy front. `0` for the first space. Pure, so it is unit-tested (backlog 3.6).
    public static func nextSortIndex(after spaces: [Space]) -> Int {
        (spaces.map(\.sortIndex).max() ?? -1) + 1
    }

    /// Galaxy drag-reorder (backlog 3.6): insert the moved space into the gap BEFORE `targetId`, and
    /// renumber every sortIndex to the new array position. Pure, so it is unit-tested; equal ids and an
    /// unresolved target are handled: a `targetId` that matches no space (the end sentinel) appends. The
    /// caller picks `targetId` as the tile that FOLLOWS the chosen gap, so the moved space lands exactly
    /// in the gap the affordance showed.
    public static func reorder(_ spaces: [Space], moving id: String, to targetId: String) -> [Space] {
        guard id != targetId, let from = spaces.firstIndex(where: { $0.id == id }) else { return spaces }
        var arr = spaces
        let moved = arr.remove(at: from)
        let dest = arr.firstIndex(where: { $0.id == targetId }) ?? arr.count   // before target, or append
        arr.insert(moved, at: dest)
        for i in arr.indices { arr[i].sortIndex = i }
        return arr
    }

    /// A rested space is alive-but-dormant: nothing is lost, it just can't reach for attention.
    public var isResting: Bool { restedAt != nil }

    /// Normalize a user-entered working directory: trim whitespace; empty/blank → nil (unset), so
    /// clearing the picker clears the field rather than storing "".
    public static func normalizeWorkingDirectory(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
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
