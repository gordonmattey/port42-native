import Foundation
import GRDB

public struct Channel: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "channels"

    public var id: String
    public var name: String
    public var type: String
    public var createdAt: Date

    public init(id: String, name: String, type: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.type = type
        self.createdAt = createdAt
    }

    public static func create(name: String, type: String = "team") -> Channel {
        Channel(
            id: UUID().uuidString,
            name: name,
            type: type,
            createdAt: Date()
        )
    }
}
