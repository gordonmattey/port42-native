import Testing
import Foundation
@testable import Port42Lib

@Suite("GeminiToolFormat")
struct GeminiToolFormatTests {

    // MARK: - ToolDefinitions.geminiFormat()

    @Test("Output structure is [{function_declarations: [...]}]")
    func outputStructure() {
        let tools = ToolDefinitions.geminiFormat()
        #expect(tools.count == 1)
        let wrapper = tools[0]
        let decls = wrapper["function_declarations"] as? [[String: Any]]
        #expect(decls != nil)
        #expect((decls?.count ?? 0) > 0)
    }

    @Test("No input_schema key in translated output")
    func noInputSchemaKey() {
        let tools = ToolDefinitions.geminiFormat()
        guard let decls = tools[0]["function_declarations"] as? [[String: Any]] else {
            Issue.record("No function_declarations"); return
        }
        for decl in decls {
            #expect(decl["input_schema"] == nil,
                    "Tool \(decl["name"] ?? "?") has input_schema which Gemini would reject")
        }
    }

    @Test("crease_write has required: [content] under parameters")
    func creaseWriteRequired() {
        let tools = ToolDefinitions.geminiFormat()
        guard let decls = tools[0]["function_declarations"] as? [[String: Any]],
              let tool = decls.first(where: { ($0["name"] as? String) == "crease_write" }) else {
            Issue.record("crease_write not found"); return
        }
        let params = tool["parameters"] as? [String: Any]
        let required = params?["required"] as? [String]
        #expect(required?.contains("content") == true)
    }

    @Test("position_set has required: [read] under parameters")
    func positionSetRequired() {
        let tools = ToolDefinitions.geminiFormat()
        guard let decls = tools[0]["function_declarations"] as? [[String: Any]],
              let tool = decls.first(where: { ($0["name"] as? String) == "position_set" }) else {
            Issue.record("position_set not found"); return
        }
        let params = tool["parameters"] as? [String: Any]
        let required = params?["required"] as? [String]
        #expect(required?.contains("read") == true)
    }

    @Test("All tool names from ToolDefinitions.all appear in translated output")
    func allToolNamesPresent() {
        let anthropicNames = Set(ToolDefinitions.all.compactMap { $0["name"] as? String })
        let tools = ToolDefinitions.geminiFormat()
        guard let decls = tools[0]["function_declarations"] as? [[String: Any]] else {
            Issue.record("No function_declarations"); return
        }
        let geminiNames = Set(decls.compactMap { $0["name"] as? String })
        #expect(anthropicNames == geminiNames)
    }

    @Test("Each declaration has name and description")
    func declarationsHaveRequiredFields() {
        let tools = ToolDefinitions.geminiFormat()
        guard let decls = tools[0]["function_declarations"] as? [[String: Any]] else {
            Issue.record("No function_declarations"); return
        }
        for decl in decls {
            let name = decl["name"] as? String
            let desc = decl["description"] as? String
            #expect(name != nil, "Missing name in declaration")
            #expect(desc != nil, "Missing description in declaration for \(name ?? "?")")
        }
    }

    // MARK: - GeminiEngine.translateTools()

    @Test("translateTools converts input_schema to parameters")
    func translateToolsConversion() {
        let anthropicTools: [[String: Any]] = [
            [
                "name": "test_tool",
                "description": "A test tool",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "value": ["type": "string", "description": "A value"]
                    ],
                    "required": ["value"]
                ] as [String: Any]
            ]
        ]

        let result = GeminiEngine.translateTools(anthropicTools)
        #expect(result.count == 1)
        guard let decls = result[0]["function_declarations"] as? [[String: Any]],
              let decl = decls.first else {
            Issue.record("No declarations"); return
        }

        #expect(decl["name"] as? String == "test_tool")
        #expect(decl["input_schema"] == nil)
        let params = decl["parameters"] as? [String: Any]
        #expect(params?["type"] as? String == "object")
        let required = params?["required"] as? [String]
        #expect(required?.contains("value") == true)
    }

    @Test("translateTools handles tools with no input_schema")
    func translateToolsNoSchema() {
        let anthropicTools: [[String: Any]] = [
            ["name": "minimal_tool", "description": "No schema"]
        ]
        let result = GeminiEngine.translateTools(anthropicTools)
        guard let decls = result[0]["function_declarations"] as? [[String: Any]],
              let decl = decls.first else {
            Issue.record("No declarations"); return
        }
        #expect(decl["name"] as? String == "minimal_tool")
        #expect(decl["parameters"] == nil)
    }
}
