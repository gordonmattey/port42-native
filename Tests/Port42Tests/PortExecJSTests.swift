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

    @Test("FOOTGUN: a multi-statement one-liner with no return mis-wraps to invalid JS")
    func footgunMultiStatementOneLiner() {
        // `foo(); 42` has no return/throw/newline, so it takes the bare-expression branch and becomes
        // `return (foo(); 42);` — a JS syntax error surfaced as the opaque "A JavaScript exception
        // occurred". Multi-statement bodies MUST use an explicit `return` or newlines. This pins the
        // shape so the footgun is not silently reshaped by a future edit.
        #expect(PortExecJS.wrapBody("foo(); 42") == "return (foo(); 42);")
    }

    @Test("timeout error carries actionable guidance about long-lived promises")
    func timeoutMessage() {
        // The guard that keeps a returned subscribe stream (or any never-resolving promise) from
        // hanging the exec task. The message must point the caller at the actual cause.
        let msg = PortExecError.timedOut(seconds: 30).errorDescription ?? ""
        #expect(msg.contains("30s"))
        #expect(msg.contains("subscribe"))
    }
}
