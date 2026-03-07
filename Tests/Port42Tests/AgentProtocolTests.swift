import Testing
import Foundation
@testable import Port42Lib

@Suite("Agent JSON Protocol")
struct AgentProtocolTests {

    // MARK: - Event Serialization (what we send to agent stdin)

    @Test("Serialize mention event")
    func serializeMentionEvent() throws {
        let event = AgentEvent.mention(
            messageId: "msg-1",
            content: "@ai-engineer review this code",
            sender: "Gordon",
            senderId: "user-1",
            channel: "builders",
            channelId: "chan-1",
            timestamp: Date(timeIntervalSince1970: 1000),
            history: [
                AgentEvent.HistoryEntry(sender: "Alice", content: "check this out", timestamp: "2026-03-06T14:00:00Z")
            ]
        )

        let data = try AgentProtocol.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["event"] as? String == "mention")
        #expect(json["content"] as? String == "@ai-engineer review this code")
        #expect(json["sender"] as? String == "Gordon")
        #expect(json["channel"] as? String == "builders")

        let history = json["history"] as! [[String: Any]]
        #expect(history.count == 1)
        #expect(history[0]["sender"] as? String == "Alice")
    }

    @Test("Serialize message event")
    func serializeMessageEvent() throws {
        let event = AgentEvent.message(
            messageId: "msg-2",
            content: "hello everyone",
            sender: "Bob",
            senderId: "user-2",
            channel: "team",
            channelId: "chan-2",
            timestamp: Date(timeIntervalSince1970: 2000),
            history: []
        )

        let data = try AgentProtocol.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["event"] as? String == "message")
        #expect(json["content"] as? String == "hello everyone")
    }

    @Test("Serialize shutdown event")
    func serializeShutdownEvent() throws {
        let event = AgentEvent.shutdown

        let data = try AgentProtocol.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["event"] as? String == "shutdown")
    }

    @Test("Encoded event ends with newline")
    func eventEndsWithNewline() throws {
        let event = AgentEvent.shutdown
        let data = try AgentProtocol.encode(event)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.hasSuffix("\n"))
    }

    @Test("Encoded event is single line (NDJSON)")
    func eventIsSingleLine() throws {
        let event = AgentEvent.mention(
            messageId: "m", content: "test", sender: "X", senderId: "u",
            channel: "c", channelId: "ci",
            timestamp: Date(), history: []
        )
        let data = try AgentProtocol.encode(event)
        let str = String(data: data, encoding: .utf8)!
        let lines = str.split(separator: "\n")
        #expect(lines.count == 1)
    }

    // MARK: - Response Parsing (what we read from agent stdout)

    @Test("Parse simple response")
    func parseSimpleResponse() throws {
        let json = #"{"content": "Here is my analysis..."}"#
        let response = try AgentProtocol.decode(json.data(using: .utf8)!)

        #expect(response.content == "Here is my analysis...")
        #expect(response.replyTo == nil)
    }

    @Test("Parse response with reply_to")
    func parseResponseWithReplyTo() throws {
        let json = #"{"content": "Replying to that", "reply_to": "msg-123"}"#
        let response = try AgentProtocol.decode(json.data(using: .utf8)!)

        #expect(response.content == "Replying to that")
        #expect(response.replyTo == "msg-123")
    }

    @Test("Parse response with metadata")
    func parseResponseWithMetadata() throws {
        let json = #"{"content": "done", "metadata": {"tokens": 150}}"#
        let response = try AgentProtocol.decode(json.data(using: .utf8)!)

        #expect(response.content == "done")
        #expect(response.metadata != nil)
    }

    @Test("Reject empty content")
    func rejectEmptyContent() throws {
        let json = #"{"content": ""}"#
        #expect(throws: AgentProtocolError.self) {
            try AgentProtocol.decode(json.data(using: .utf8)!)
        }
    }

    @Test("Reject missing content field")
    func rejectMissingContent() throws {
        let json = #"{"reply_to": "msg-1"}"#
        #expect(throws: (any Error).self) {
            try AgentProtocol.decode(json.data(using: .utf8)!)
        }
    }

    @Test("Handle extra fields gracefully")
    func handleExtraFields() throws {
        let json = #"{"content": "hello", "unknown_field": 42, "extra": true}"#
        let response = try AgentProtocol.decode(json.data(using: .utf8)!)
        #expect(response.content == "hello")
    }
}
