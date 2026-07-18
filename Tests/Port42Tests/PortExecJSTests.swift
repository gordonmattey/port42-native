import Testing
import Foundation
@testable import Port42Lib

// #5: the pure body-wrapping logic. The live callAsyncJavaScript behavior (await, serialization,
// {error}) is verified against the running app's gateway, not here (it needs a real webview).

@Suite("port.exec — body wrapping")
struct PortExecJSTests {

    @Test("a bare expression is wrapped as return(expr) so it yields (and auto-awaits a promise)")
    func bareExpression() {
        #expect(PortExecJS.wrapBody("port42.ports.list()") == "return (port42.ports.list());")
        #expect(PortExecJS.wrapBody("document.title") == "return (document.title);")
    }

    @Test("a trailing semicolon on an expression is tolerated")
    func trailingSemicolon() {
        #expect(PortExecJS.wrapBody("1 + 1;") == "return (1 + 1);")
    }

    @Test("a body with an explicit return is used as-is")
    func explicitReturn() {
        let js = "return await port42.ports.list()"
        #expect(PortExecJS.wrapBody(js) == js)
    }

    @Test("a throw is treated as a body, not wrapped")
    func throwBody() {
        let js = "throw new Error('x')"
        #expect(PortExecJS.wrapBody(js) == js)
    }

    @Test("a multi-line body is used as-is")
    func multiLine() {
        let js = "const r = await port42.ports.list();\nreturn r.length"
        #expect(PortExecJS.wrapBody(js) == js)
    }
}
