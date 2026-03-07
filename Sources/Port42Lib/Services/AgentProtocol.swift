import Foundation

// MARK: - Events (sent to agent stdin)

public enum AgentEvent {
    public struct HistoryEntry: Codable {
        public let sender: String
        public let content: String
        public let timestamp: String

        public init(sender: String, content: String, timestamp: String) {
            self.sender = sender
            self.content = content
            self.timestamp = timestamp
        }
    }

    case mention(
        messageId: String, content: String, sender: String, senderId: String,
        channel: String, channelId: String, timestamp: Date, history: [HistoryEntry]
    )
    case message(
        messageId: String, content: String, sender: String, senderId: String,
        channel: String, channelId: String, timestamp: Date, history: [HistoryEntry]
    )
    case shutdown
}

// MARK: - Response (read from agent stdout)

public struct AgentResponse: Codable {
    public let content: String
    public let replyTo: String?
    public let metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case content
        case replyTo = "reply_to"
        case metadata
    }
}

// MARK: - AnyCodable helper for metadata

public struct AnyCodable: Codable, Equatable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else { value = NSNull() }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let int = value as? Int { try container.encode(int) }
        else if let double = value as? Double { try container.encode(double) }
        else if let string = value as? String { try container.encode(string) }
        else if let bool = value as? Bool { try container.encode(bool) }
        else { try container.encodeNil() }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

// MARK: - Errors

public enum AgentProtocolError: Error {
    case emptyContent
    case invalidJSON
    case encodingFailed
}

// MARK: - Protocol Codec

public enum AgentProtocol {

    public static func encode(_ event: AgentEvent) throws -> Data {
        var dict: [String: Any] = [:]
        let isoFormatter = ISO8601DateFormatter()

        switch event {
        case .mention(let messageId, let content, let sender, let senderId,
                      let channel, let channelId, let timestamp, let history):
            dict["event"] = "mention"
            dict["message_id"] = messageId
            dict["content"] = content
            dict["sender"] = sender
            dict["sender_id"] = senderId
            dict["channel"] = channel
            dict["channel_id"] = channelId
            dict["timestamp"] = isoFormatter.string(from: timestamp)
            dict["history"] = history.map { entry in
                ["sender": entry.sender, "content": entry.content, "timestamp": entry.timestamp]
            }

        case .message(let messageId, let content, let sender, let senderId,
                      let channel, let channelId, let timestamp, let history):
            dict["event"] = "message"
            dict["message_id"] = messageId
            dict["content"] = content
            dict["sender"] = sender
            dict["sender_id"] = senderId
            dict["channel"] = channel
            dict["channel_id"] = channelId
            dict["timestamp"] = isoFormatter.string(from: timestamp)
            dict["history"] = history.map { entry in
                ["sender": entry.sender, "content": entry.content, "timestamp": entry.timestamp]
            }

        case .shutdown:
            dict["event"] = "shutdown"
        }

        let jsonData = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard var str = String(data: jsonData, encoding: .utf8) else {
            throw AgentProtocolError.encodingFailed
        }
        str += "\n"
        guard let result = str.data(using: .utf8) else {
            throw AgentProtocolError.encodingFailed
        }
        return result
    }

    public static func decode(_ data: Data) throws -> AgentResponse {
        let decoder = JSONDecoder()
        let response = try decoder.decode(AgentResponse.self, from: data)
        if response.content.isEmpty {
            throw AgentProtocolError.emptyContent
        }
        return response
    }
}
