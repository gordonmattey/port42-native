import Testing
import Foundation
@testable import Port42Lib

@Suite("GeminiToolFormat")
@MainActor
struct GeminiToolFormatTests {

    // The Gemini tool path is GeminiEngine.translateTools, fed the generated tool list. (The old
    // ToolDefinitions.geminiFormat was dead and was removed with the hand-written schema deletion.)

    @Test("translateTools preserves the generated tool set and required fields")
    func translatesGeneratedTools() throws {
        let world = try makeParityWorld()
        let generated = world.state.generatedToolDefinitions()
        let result = GeminiEngine.translateTools(generated)

        #expect(result.count == 1)
        guard let decls = result[0]["function_declarations"] as? [[String: Any]] else {
            Issue.record("No function_declarations"); return
        }
        // Same tool set, no input_schema key, each has name + description.
        let genNames = Set(generated.compactMap { $0["name"] as? String })
        let geminiNames = Set(decls.compactMap { $0["name"] as? String })
        #expect(genNames == geminiNames)
        for decl in decls {
            #expect(decl["input_schema"] == nil, "Gemini would reject input_schema on \(decl["name"] ?? "?")")
            #expect(decl["name"] as? String != nil)
            #expect(decl["description"] as? String != nil)
        }
        // A representative required-field survives the translation.
        if let crease = decls.first(where: { ($0["name"] as? String) == "crease_write" }) {
            let required = (crease["parameters"] as? [String: Any])?["required"] as? [String]
            #expect(required?.contains("content") == true)
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
