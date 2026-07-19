import Testing
import Foundation
@testable import Port42Lib

@Suite("Port Capabilities")
@MainActor
struct PortCapabilityTests {

    // MARK: - Tool schema (generated list — the hand-written ToolDefinitions.all is gone)

    @Test("ports_list schema includes capabilities filter property")
    func portsListHasCapabilitiesProperty() throws {
        let defs = try generatedToolList()
        guard let tool = defs.first(where: { $0["name"] as? String == "ports_list" }),
              let schema = tool["input_schema"] as? [String: Any],
              let props = schema["properties"] as? [String: Any] else {
            Issue.record("ports_list tool or schema not found")
            return
        }
        #expect(props["capabilities"] != nil)
    }

    @Test("ports_list description mentions capabilities")
    func portsListDescriptionMentionsCapabilities() throws {
        let defs = try generatedToolList()
        guard let tool = defs.first(where: { $0["name"] as? String == "ports_list" }),
              let desc = tool["description"] as? String else {
            Issue.record("ports_list tool not found")
            return
        }
        #expect(desc.contains("capabilities"))
    }

    // terminal_send is gone (uniform port.create sweep); port_push is the verb that now drives
    // terminals, so it carries the routing-by-id guidance instead.
    @Test("port_push description mentions UDID or id")
    func portPushMentionsUDID() throws {
        let defs = try generatedToolList()
        guard let tool = defs.first(where: { $0["name"] as? String == "port_push" }),
              let desc = tool["description"] as? String else {
            Issue.record("port_push tool not found")
            return
        }
        #expect(desc.contains("UDID") || desc.contains("id"))
    }

    @Test("port_push id parameter description mentions UDID")
    func portPushIdParamMentionsUDID() throws {
        let defs = try generatedToolList()
        guard let tool = defs.first(where: { $0["name"] as? String == "port_push" }),
              let schema = tool["input_schema"] as? [String: Any],
              let props = schema["properties"] as? [String: Any],
              let idParam = props["id"] as? [String: Any],
              let idDesc = idParam["description"] as? String else {
            Issue.record("port_push tool or id param not found")
            return
        }
        #expect(idDesc.contains("UDID") || idDesc.contains("id"))
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
        // terminals are driven through the port verbs now, not a parallel terminal toolset
        #expect(content.contains("port_push"))
        #expect(content.contains("port_create"))
        #expect(!content.contains("terminal_send"))
        #expect(!content.contains("terminal_spawn"))
    }
}
