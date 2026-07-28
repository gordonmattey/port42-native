import Foundation
import WebKit

// MARK: - port.exec JS execution (#5 fix)
//
// The old path ran `webView.evaluateJavaScript(js)`, which has two bugs:
//   1. it does NOT await promises — every `port42.*` call returns a Promise, so the caller got the
//      unresolved Promise back ("unsupported type"), and
//   2. object results come back as NSDictionary/NSArray that the result serializer rejects.
//
// `callAsyncJavaScript` fixes both: it runs the string as an ASYNC FUNCTION BODY (so `await`/`return`
// work and a returned promise is auto-awaited), and it only yields JSON-serializable values. We run it
// in the `.page` content world — the world the port42 bridge is injected into (`PortBridge.attach`
// uses `addUserScript` with no world = page) — so `port42.*` is visible to the exec'd code.

public enum PortExecError: LocalizedError {
    /// The exec body did not settle within the bound. Almost always because the body RETURNED a
    /// long-lived promise (e.g. `return port42.port.subscribe(...)`, whose stream resolves only on
    /// cancel) — `callAsyncJavaScript` auto-awaits it, so without this bound the task would hang and
    /// leak forever. Start the stream and return a plain value; keep the handle in a variable.
    case timedOut(seconds: Int)

    /// The JS itself failed. Carries the message WebKit gave and the body we actually ran, because
    /// the two differ: an expression is wrapped as `return (…)`, so a caller reading only their own
    /// source cannot see what the engine was handed.
    ///
    /// It exists because `port.exec` failures used to surface as the bare string "A JavaScript
    /// exception occurred" with NO CODE AT ALL, so an agent could not branch on the failure and a
    /// human got no hint (register §5).
    case jsFailed(message: String, ran: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let s):
            return "port.exec did not return within \(s)s. If the body returns a long-lived promise "
                + "(e.g. `return port42.port.subscribe(...)`, which resolves only on cancel), return a "
                + "plain value instead and keep the subscription handle in a variable."
        case .jsFailed(let m, let ran):
            let hint = m.contains("SyntaxError") && ran.hasPrefix("return (")
                ? " (this ran as an EXPRESSION; a multi-statement body needs an explicit `return`, "
                + "e.g. `foo(); return 42;`)"
                : ""
            return "\(m)\(hint)"
        }
    }

    /// The machine-actionable code. A caller branches on this; the message is for a human.
    public var code: BridgeErrorCode {
        switch self {
        case .timedOut:  return .jsTimeout
        case .jsFailed(let m, _): return m.contains("SyntaxError") ? .jsSyntax : .jsError
        }
    }
}

public enum PortExecJS {

    /// Default upper bound on a single `port.exec` body (seconds). Generous enough for a legitimate
    /// `return await …` yet finite, so a body that returns a never-resolving promise cannot wedge the
    /// awaiting task. Callers that genuinely need longer pass an explicit `timeout`.
    public static let defaultTimeoutSeconds = 30

    /// Wrap the caller's JS into an async function body. The contract is "return-to-yield": a body
    /// that RETURNS or THROWS is used as-is; anything else is an expression and is wrapped as
    /// `return (expr)`, so `port.exec("port42.ports.list()")` still yields the array (the promise is
    /// auto-awaited). A trailing `;` is tolerated.
    ///
    /// **This used to be `t.contains("return") || t.contains("throw") || t.contains("\n")`, and that
    /// substring match failed SILENTLY.** Measured live against a port holding
    /// `<b id=returned>THE VALUE</b>`:
    ///
    /// ```
    /// 'hello'                                          → "hello"      correct
    /// 'returned'                                       → {ok: true}   the value vanished
    /// document.querySelector('#returned').textContent  → {ok: true}   the value vanished
    /// ```
    ///
    /// The word only had to APPEAR — in a string, an id, a selector, a comment, an identifier like
    /// `returnValue` — for the wrap to be skipped, leaving a bare expression statement with no
    /// return. The caller asked for a value and got a success with nothing in it, and nothing said
    /// why. A silent wrong answer is worse than the loud syntax error this doc used to warn about.
    ///
    /// **Why not decide it in the page.** The obvious fix is a compile-only trial there
    /// (`new Function(src)` inside a try), which is exact and has no side effects. Generated ports
    /// ship a CSP with `script-src 'unsafe-inline'` and no `unsafe-eval`, and a browser port carries
    /// whatever CSP the site sets, so that answer is not available everywhere it would be needed.
    ///
    /// **Why not run it and retry on failure.** Retrying after a *runtime* SyntaxError would execute
    /// a body that had already run its side effects a second time.
    ///
    /// So it is decided here, by scanning the source as JS rather than as text: string and template
    /// literals, comments and regex literals are skipped, and only a real `return`/`throw` KEYWORD
    /// counts. A newline no longer forces body mode either — that alone broke every pretty-printed
    /// expression.
    ///
    /// STILL LOUD, deliberately: a multi-statement one-liner with no return (`foo(); 42`) is wrapped
    /// and fails to compile. Treating it as a body would return undefined and say nothing, which is
    /// the silent class again. The error now carries `js_syntax` and names the fix.
    public static func wrapBody(_ js: String) -> String {
        let t = js.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasTopLevelKeyword(t) { return js }   // caller-provided async body
        let expr = t.hasSuffix(";") ? String(t.dropLast()) : t
        return "return (\(expr));"
    }

    /// True when `return` or `throw` appears as a KEYWORD in this source, rather than inside a
    /// string, a template, a comment or a regex.
    ///
    /// Not a JS parser, and it does not need to be: the question is only "did the author write a
    /// return statement", and every wrong answer the old check gave came from matching text that was
    /// never code. A keyword is bounded by non-identifier characters on both sides, which is what
    /// separates `return x` from `returnValue` and `#returned`.
    static func hasTopLevelKeyword(_ src: String) -> Bool {
        let chars = Array(src)
        var i = 0
        // Whether a `/` here starts a regex or is division: after a value it divides, otherwise it
        // opens a literal. Tracked crudely, since the only cost of being wrong is scanning a regex
        // body as code, and a keyword cannot appear there without being a keyword anyway.
        var afterValue = false

        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"", "'", "`":
                let quote = c
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == quote { i += 1; break }
                    i += 1
                }
                afterValue = true
            case "/" where i + 1 < chars.count && chars[i + 1] == "/":
                while i < chars.count && chars[i] != "\n" { i += 1 }
            case "/" where i + 1 < chars.count && chars[i + 1] == "*":
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
            case "/" where !afterValue:
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "/" { i += 1; break }
                    i += 1
                }
                afterValue = true
            default:
                if isIdent(c) {
                    let start = i
                    while i < chars.count && isIdent(chars[i]) { i += 1 }
                    let word = String(chars[start..<i])
                    if word == "return" || word == "throw" { return true }
                    afterValue = !(word == "typeof" || word == "new" || word == "in"
                                   || word == "of" || word == "instanceof")
                } else {
                    afterValue = (c == ")" || c == "]")
                    i += 1
                }
            }
        }
        return false
    }

    /// Run JS in a port's webview and return a JSON-serializable result (or nil for undefined/null).
    /// Throws on a JS exception / rejected promise (the caller renders that as `{error}`), or
    /// `PortExecError.timedOut` if the body does not settle within `timeoutSeconds` — the guard that
    /// keeps a returned long-lived promise (subscribe stream, infinite await) from leaking this task.
    @MainActor
    public static func run(_ webView: WKWebView, _ js: String,
                           timeoutSeconds: Int = defaultTimeoutSeconds) async throws -> Any? {
        let body = wrapBody(js)
        let result: Any? = try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask { @MainActor in
                do {
                    return try await webView.callAsyncJavaScript(body, arguments: [:], in: nil,
                                                                 contentWorld: .page)
                } catch {
                    // WebKit reports every JS failure as one opaque error. Pull out the actual
                    // exception text so the caller gets "SyntaxError: …" rather than "A JavaScript
                    // exception occurred", and carry the body we RAN, which is not the source the
                    // caller sent when an expression was wrapped.
                    let ns = error as NSError
                    let msg = (ns.userInfo["WKJavaScriptExceptionMessage"] as? String)
                        ?? ns.localizedDescription
                    throw PortExecError.jsFailed(message: msg, ran: body)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw PortExecError.timedOut(seconds: timeoutSeconds)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        if result is NSNull { return nil }
        return result
    }
}
