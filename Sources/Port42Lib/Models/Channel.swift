import Foundation
import GRDB

public struct Channel: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "channels"

    public var id: String
    public var name: String
    public var type: String
    public var createdAt: Date
    /// Base64-encoded AES-256-GCM symmetric key for E2E encryption.
    /// Nil for channels created before encryption was added.
    public var encryptionKey: String?

    public init(id: String, name: String, type: String, createdAt: Date, encryptionKey: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.createdAt = createdAt
        self.encryptionKey = encryptionKey
    }

    public static func create(name: String, type: String = "team") -> Channel {
        Channel(
            id: UUID().uuidString,
            name: name,
            type: type,
            createdAt: Date(),
            encryptionKey: ChannelCrypto.generateKey()
        )
    }
}
