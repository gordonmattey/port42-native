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

    // MARK: - the SILENT failure the substring match caused (measured live, 2026-07-27)

    @Test("the word `return` INSIDE A STRING is not a return statement")
    func returnInsideAString() {
        // Measured against a live port holding <b id=returned>THE VALUE</b>: exec of `'returned'`
        // came back {ok: true} with the value gone, because the source merely CONTAINED the word.
        // A silent wrong answer, not an error — the caller asked for a value and got a success
        // holding nothing.
        #expect(PortExecJS.wrapBody("'returned'") == "return ('returned');")
        #expect(PortExecJS.wrapBody("document.querySelector('#returned').textContent")
                == "return (document.querySelector('#returned').textContent);")
        #expect(PortExecJS.wrapBody("document.querySelector('.throwaway').value")
                == "return (document.querySelector('.throwaway').value);")
    }

    @Test("an identifier that merely starts with the keyword is not the keyword")
    func identifierPrefix() {
        #expect(PortExecJS.wrapBody("e.returnValue") == "return (e.returnValue);")
        #expect(PortExecJS.wrapBody("thrown") == "return (thrown);")
    }

    @Test("a keyword in a comment is not a return statement")
    func keywordInComment() {
        #expect(PortExecJS.wrapBody("x /* return y */") == "return (x /* return y */);")
        #expect(PortExecJS.hasTopLevelKeyword("// return 1") == false)
    }

    @Test("a NEWLINE alone no longer forces body mode — that broke pretty-printed expressions")
    func multiLineExpression() {
        // The old rule treated any newline as "this is a body", so formatting an expression across
        // two lines silently returned nothing. Only a real keyword decides now.
        let js = "document\n  .querySelector('#x')\n  .textContent"
        #expect(PortExecJS.wrapBody(js) == "return (\(js));")
    }

    @Test("a real return or throw still wins, wherever it sits")
    func realKeywordsStillDetected() {
        #expect(PortExecJS.hasTopLevelKeyword("if (a) { return 1 } return 2"))
        #expect(PortExecJS.hasTopLevelKeyword("const s = 'x'; return s"))
        #expect(PortExecJS.hasTopLevelKeyword("throw new Error('x')"))
        // …and a keyword after a regex literal, which the scanner has to step over.
        #expect(PortExecJS.hasTopLevelKeyword("const m = /a\\/b/; return m"))
    }

    @Test("a JS failure carries a CODE, not just prose")
    func jsFailureIsActionable() {
        // register §5: it used to surface as the bare string "A JavaScript exception occurred" with
        // no code at all, so an agent could not branch on it.
        let syntax = PortExecError.jsFailed(message: "SyntaxError: Unexpected token ';'",
                                            ran: "return (foo(); 42);")
        #expect(syntax.code == "js_syntax")
        #expect(syntax.errorDescription?.contains("explicit `return`") == true,
                "a syntax error from a WRAPPED expression must name the fix")

        let runtime = PortExecError.jsFailed(message: "TypeError: undefined is not an object", ran: "return (x.y);")
        #expect(runtime.code == "js_error")
        #expect(runtime.errorDescription?.contains("TypeError") == true)
        #expect(PortExecError.timedOut(seconds: 30).code == "js_timeout")
    }

    @Test("FOOTGUN: a multi-statement one-liner with no return mis-wraps to invalid JS")
    func footgunMultiStatementOneLiner() {
        // `foo(); 42` has no return or throw, so it takes the bare-expression branch and becomes
        // `return (foo(); 42);` — a JS syntax error. STILL LOUD ON PURPOSE: treating it as a body
        // instead would run it and return undefined, saying nothing, which is the silent class that
        // the substring match produced. The error now carries `js_syntax` and names the fix.
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
