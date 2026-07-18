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

public enum PortExecJS {

    /// Wrap the caller's JS into an async function body. The contract (#5) is "return-to-yield": a body
    /// with an explicit `return`/`throw` (or multiple lines) is used as-is; a bare expression is
    /// wrapped as `return (expr)` so `port.exec("port42.ports.list()")` still yields the array (the
    /// promise is auto-awaited). A trailing `;` on an expression is tolerated.
    public static func wrapBody(_ js: String) -> String {
        let t = js.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("return") || t.contains("throw") || t.contains("\n") {
            return js   // caller-provided async body
        }
        let expr = t.hasSuffix(";") ? String(t.dropLast()) : t
        return "return (\(expr));"
    }

    /// Run JS in a port's webview and return a JSON-serializable result (or nil for undefined/null).
    /// Throws on a JS exception / rejected promise (the caller renders that as `{error}`).
    @MainActor
    public static func run(_ webView: WKWebView, _ js: String) async throws -> Any? {
        let result = try await webView.callAsyncJavaScript(
            wrapBody(js), arguments: [:], in: nil, contentWorld: .page)
        if result is NSNull { return nil }
        return result
    }
}
