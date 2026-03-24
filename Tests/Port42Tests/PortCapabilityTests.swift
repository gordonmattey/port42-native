import Testing
import Foundation
@testable import Port42Lib

@Suite("Port Capabilities")
struct PortCapabilityTests {

    // MARK: - ToolDefinitions schema

    @Test("ports_list schema includes capabilities filter property")
    func portsListHasCapabilitiesProperty() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "ports_list" }),
              let schema = tool["input_schema"] as? [String: Any],
              let props = schema["properties"] as? [String: Any] else {
            Issue.record("ports_list tool or schema not found")
            return
        }
        #expect(props["capabilities"] != nil)
    }

    @Test("ports_list description mentions capabilities")
    func portsListDescriptionMentionsCapabilities() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "ports_list" }),
              let desc = tool["description"] as? String else {
            Issue.record("ports_list tool not found")
            return
        }
        #expect(desc.contains("capabilities"))
    }

    @Test("terminal_send description mentions UDID or id")
    func terminalSendMentionsUDID() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "terminal_send" }),
              let desc = tool["description"] as? String else {
            Issue.record("terminal_send tool not found")
            return
        }
        #expect(desc.contains("UDID") || desc.contains("id"))
    }

    @Test("terminal_send name parameter description mentions UDID")
    func terminalSendNameParamMentionsUDID() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "terminal_send" }),
              let schema = tool["input_schema"] as? [String: Any],
              let props = schema["properties"] as? [String: Any],
              let nameParam = props["name"] as? [String: Any],
              let nameDesc = nameParam["description"] as? String else {
            Issue.record("terminal_send tool or name param not found")
            return
        }
        #expect(nameDesc.contains("UDID") || nameDesc.contains("id"))
    }

    // MARK: - ports-context.txt content

    @Test("ports-context.txt contains conversation tool-use section")
    func portsContextHasToolUseSection() throws {
        // Bundle.port42 doesn't work in test contexts — read from source directly
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Port42Tests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/Port42Lib/Resources/ports-context.txt")
        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(content.contains("Interacting With Ports From Conversation"))
        #expect(content.contains("ports_list(capabilities"))
        #expect(content.contains("terminal_send"))
    }
}
