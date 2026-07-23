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
    public var errorDescription: String? {
        switch self {
        case .timedOut(let s):
            return "port.exec did not return within \(s)s. If the body returns a long-lived promise "
                + "(e.g. `return port42.port.subscribe(...)`, which resolves only on cancel), return a "
                + "plain value instead and keep the subscription handle in a variable."
        }
    }
}

public enum PortExecJS {

    /// Default upper bound on a single `port.exec` body (seconds). Generous enough for a legitimate
    /// `return await …` yet finite, so a body that returns a never-resolving promise cannot wedge the
    /// awaiting task. Callers that genuinely need longer pass an explicit `timeout`.
    public static let defaultTimeoutSeconds = 30

    /// Wrap the caller's JS into an async function body. The contract (#5) is "return-to-yield": a body
    /// with an explicit `return`/`throw` (or multiple lines) is used as-is; a bare expression is
    /// wrapped as `return (expr)` so `port.exec("port42.ports.list()")` still yields the array (the
    /// promise is auto-awaited). A trailing `;` on an expression is tolerated.
    ///
    /// FOOTGUN: a multi-statement ONE-LINER with no explicit `return` and no newline — e.g.
    /// `foo(); 42` — hits the bare-expression branch and is wrapped as `return (foo(); 42)`, which is
    /// a JS SYNTAX ERROR surfaced as the opaque "A JavaScript exception occurred". Multi-statement
    /// bodies MUST use an explicit `return` or newlines. `PortExecJSTests` locks this shape.
    public static func wrapBody(_ js: String) -> String {
        let t = js.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("return") || t.contains("throw") || t.contains("\n") {
            return js   // caller-provided async body
        }
        let expr = t.hasSuffix(";") ? String(t.dropLast()) : t
        return "return (\(expr));"
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
                try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
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
