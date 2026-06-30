import Testing
import Foundation
@testable import Port42Lib

@Suite("Port Create")
struct PortCreateTests {

    // MARK: - Validation (pure)

    @Test("web with html resolves to .web")
    func webWithHtml() {
        #expect(PortCreateValidation.validate(type: "web", html: "<h1>hi</h1>", command: nil)
                == .ok(.web(html: "<h1>hi</h1>")))
    }

    @Test("terminal with command resolves to .terminal")
    func terminalWithCommand() {
        #expect(PortCreateValidation.validate(type: "terminal", html: nil, command: "bash")
                == .ok(.terminal(command: "bash")))
    }

    @Test("unknown type errors")
    func unknownType() {
        guard case .error = PortCreateValidation.validate(type: "bogus", html: "<h1/>", command: "bash") else {
            Issue.record("expected .error for unknown type"); return
        }
    }

    @Test("missing type errors")
    func missingType() {
        guard case .error = PortCreateValidation.validate(type: nil, html: "<h1/>", command: "bash") else {
            Issue.record("expected .error for missing type"); return
        }
    }

    @Test("web without html errors")
    func webWithoutHtml() {
        guard case .error = PortCreateValidation.validate(type: "web", html: nil, command: nil) else {
            Issue.record("expected .error for web without html"); return
        }
    }

    @Test("web with whitespace-only html errors")
    func webWithBlankHtml() {
        guard case .error = PortCreateValidation.validate(type: "web", html: "   \n ", command: nil) else {
            Issue.record("expected .error for blank html"); return
        }
    }

    @Test("terminal without command errors")
    func terminalWithoutCommand() {
        guard case .error = PortCreateValidation.validate(type: "terminal", html: nil, command: nil) else {
            Issue.record("expected .error for terminal without command"); return
        }
    }

    @Test("inputs are trimmed before resolving")
    func trimsInputs() {
        #expect(PortCreateValidation.validate(type: "terminal", html: nil, command: "  htop  ")
                == .ok(.terminal(command: "htop")))
    }

    // MARK: - Tool surface

    @Test("port_create is registered as a tool")
    func portCreateRegistered() {
        let names = ToolDefinitions.all.compactMap { $0["name"] as? String }
        #expect(names.contains("port_create"))
    }

    @Test("port_create needs no permission (ungated)")
    func portCreateUngated() {
        #expect(ToolDefinitions.permission(for: "port_create") == nil)
    }

    @Test("port.create bridge method needs no permission (ungated)")
    func portCreateBridgeUngated() {
        #expect(PortPermission.permissionForMethod("port.create") == nil)
    }
}
