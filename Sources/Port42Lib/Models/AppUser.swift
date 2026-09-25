import Foundation
import GRDB

public struct AppUser: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "users"

    public var id: String
    public var displayName: String
    public var avatarData: Data?
    public var isLocal: Bool
    public var createdAt: Date

    public init(id: String, displayName: String, avatarData: Data?, isLocal: Bool,
                createdAt: Date) {
        self.id = id
        self.displayName = displayName
        self.avatarData = avatarData
        self.isLocal = isLocal
        self.createdAt = createdAt
    }

    /// Test-only factory. Identical to `createLocal` now that a user carries no key material.
    public static func createForTesting(displayName: String) -> AppUser {
        createLocal(displayName: displayName)
    }

    public static func createLocal(displayName: String) -> AppUser {
        AppUser(id: UUID().uuidString, displayName: displayName, avatarData: nil, isLocal: true,
                createdAt: Date())
    }
}
