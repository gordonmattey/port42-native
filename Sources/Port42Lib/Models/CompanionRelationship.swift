import Foundation
import GRDB

// MARK: - CompanionPosition

/// The companion's live read of a channel — not stored opinions but active interpretation.
/// What the companion currently thinks is happening, what it thinks needs to happen,
/// and what signals it's watching that would confirm or change that read.
public struct CompanionPosition: FetchableRecord, MutablePersistableRecord, Codable {
    public static let databaseTableName = "companion_positions"

    public var id: String
    public var companionId: String
    public var channelId: String
    public var read: String?       // what the companion thinks is actually happening
    public var stance: String?     // what the companion thinks needs to happen
    public var watching: [String]? // signals being tracked
    public var confidence: Double
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, companionId, channelId, read, stance, watching, confidence, updatedAt
    }

    public init(
        id: String = UUID().uuidString,
        companionId: String,
        channelId: String,
        read: String? = nil,
        stance: String? = nil,
        watching: [String]? = nil,
        confidence: Double = 0.5,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.companionId = companionId
        self.channelId = channelId
        self.read = read
        self.stance = stance
        self.watching = watching
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["companionId"] = companionId
        container["channelId"] = channelId
        container["read"] = read
        container["stance"] = stance
        container["confidence"] = confidence
        container["updatedAt"] = updatedAt
        if let w = watching {
            container["watching"] = (try? JSONEncoder().encode(w)).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            container["watching"] = nil as String?
        }
    }

    public init(row: Row) throws {
        id = row["id"]
        companionId = row["companionId"]
        channelId = row["channelId"]
        read = row["read"]
        stance = row["stance"]
        confidence = row["confidence"] ?? 0.5
        updatedAt = row["updatedAt"]
        if let wStr: String = row["watching"],
           let data = wStr.data(using: .utf8) {
            watching = try? JSONDecoder().decode([String].self, from: data)
        }
    }

    /// Format for injection into LLM context.
    public func asPromptText() -> String {
        var parts: [String] = []
        if let r = read, !r.isEmpty { parts.append("Read: \(r)") }
        if let s = stance, !s.isEmpty { parts.append("Stance: \(s)") }
        if let w = watching, !w.isEmpty { parts.append("Watching: \(w.joined(separator: ", "))") }
        return parts.joined(separator: "\n")
    }

    public var isEmpty: Bool {
        (read ?? "").isEmpty && (stance ?? "").isEmpty && (watching ?? []).isEmpty
    }
}

// MARK: - CompanionCrease

/// A crease — a moment where the companion's prediction broke and something reformed.
/// Not a fact about the user. A break in the model that reshaped understanding.
public struct CompanionCrease: FetchableRecord, MutablePersistableRecord, Codable {
    public static let databaseTableName = "companion_creases"

    public var id: String
    public var companionId: String
    public var channelId: String?     // nil = global (shapes all relationships)
    public var content: String        // companion's own words about what reformed
    public var prediction: String?    // what the companion expected
    public var actual: String?        // what happened instead
    public var weight: Double
    public var createdAt: Date
    public var touchedAt: Date        // last time this shaped a response

    public init(
        id: String = UUID().uuidString,
        companionId: String,
        channelId: String?,
        content: String,
        prediction: String? = nil,
        actual: String? = nil,
        weight: Double = 1.0,
        createdAt: Date = Date(),
        touchedAt: Date = Date()
    ) {
        self.id = id
        self.companionId = companionId
        self.channelId = channelId
        self.content = content
        self.prediction = prediction
        self.actual = actual
        self.weight = weight
        self.createdAt = createdAt
        self.touchedAt = touchedAt
    }

    /// Format for injection into LLM context.
    public func asPromptText() -> String {
        var parts = [content]
        if let pred = prediction, let act = actual {
            parts.append("(expected: \(pred) / got: \(act))")
        } else if let pred = prediction {
            parts.append("(expected: \(pred))")
        } else if let act = actual {
            parts.append("(got: \(act))")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - CompanionFold

/// The fold — orientation, not data. How the companion approaches this relationship,
/// shaped by every crease that came before. Belongs to the companion×channel intersection.
public struct CompanionFold: FetchableRecord, MutablePersistableRecord, Codable {
    public static let databaseTableName = "companion_folds"

    public var id: String
    public var companionId: String
    public var channelId: String
    public var established: [String]?  // shared understandings, encoded as JSON
    public var tensions: [String]?     // unresolved threads in productive suspension
    public var holding: String?        // the one thread the companion is carrying
    public var depth: Int              // relational depth (not message count, earned)
    public var updatedAt: Date

    // Custom coding keys to handle JSON-encoded array fields
    enum CodingKeys: String, CodingKey {
        case id, companionId, channelId, established, tensions, holding, depth, updatedAt
    }

    public init(
        id: String = UUID().uuidString,
        companionId: String,
        channelId: String,
        established: [String]? = nil,
        tensions: [String]? = nil,
        holding: String? = nil,
        depth: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.companionId = companionId
        self.channelId = channelId
        self.established = established
        self.tensions = tensions
        self.holding = holding
        self.depth = depth
        self.updatedAt = updatedAt
    }

    // GRDB: encode arrays as JSON strings for storage
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["companionId"] = companionId
        container["channelId"] = channelId
        container["holding"] = holding
        container["depth"] = depth
        container["updatedAt"] = updatedAt

        if let est = established {
            container["established"] = (try? JSONEncoder().encode(est)).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            container["established"] = nil as String?
        }
        if let ten = tensions {
            container["tensions"] = (try? JSONEncoder().encode(ten)).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            container["tensions"] = nil as String?
        }
    }

    public init(row: Row) throws {
        id = row["id"]
        companionId = row["companionId"]
        channelId = row["channelId"]
        holding = row["holding"]
        depth = row["depth"] ?? 0
        updatedAt = row["updatedAt"]

        if let estStr: String = row["established"],
           let data = estStr.data(using: .utf8) {
            established = try? JSONDecoder().decode([String].self, from: data)
        }
        if let tenStr: String = row["tensions"],
           let data = tenStr.data(using: .utf8) {
            tensions = try? JSONDecoder().decode([String].self, from: data)
        }
    }

    /// Format for injection into LLM context.
    public func asPromptText() -> String {
        var parts: [String] = []
        if let est = established, !est.isEmpty {
            parts.append("Established: \(est.joined(separator: "; "))")
        }
        if let ten = tensions, !ten.isEmpty {
            parts.append("In tension: \(ten.joined(separator: "; "))")
        }
        if let h = holding, !h.isEmpty {
            parts.append("Holding: \(h)")
        }
        parts.append("Depth: \(depth)")
        return parts.joined(separator: "\n")
    }
}
