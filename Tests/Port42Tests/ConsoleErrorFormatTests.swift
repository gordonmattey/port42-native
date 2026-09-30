import Testing
import Foundation
import JavaScriptCore
@testable import Port42Lib

// A port that logged a caught error with console.error(err) reached Port42 as "{}": an Error's
// message and stack are not enumerable, so JSON.stringify drops them (a team run, 2026-09-26).
//
// The formatting is the injected console script's, so the script runs here in JavaScriptCore, the
// engine a port's page runs it in, with the message handler stubbed (#214). It used to run in a web
// view, and in the full suite on a loaded machine a web view's first page took 47 s to over 128 s to
// start: the gate logs of 2026-09-29 show the passing runs' console lines arriving that late and the
// failing runs' never arriving at all. The test failed on the wait, not on the formatting.
@Suite("A port's logged errors keep their message")
struct ConsoleErrorFormatTests {

    /// Run the console script, then `page`, and return what it posted to Port42, one line per call.
    static func forwarded(_ page: String) throws -> [String] {
        let ctx = try #require(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript("""
            var window = globalThis, posted = [];
            window.webkit = { messageHandlers: { portConsole: { postMessage: function(m) { posted.push(m.message); } } } };
            window.addEventListener = function() {};
            window.console = { log: function() {}, error: function() {}, warn: function() {} };
            """)
        ctx.evaluateScript(PortWebViewFactory.consoleJS)
        ctx.evaluateScript(page)
        #expect(thrown == nil, "the script threw: \(thrown ?? "")")
        return ctx.objectForKeyedSubscript("posted").toArray().compactMap { $0 as? String }
    }

    @Test("console.error(new Error(...)) arrives with its name and message, not {}")
    func errorKeepsMessage() throws {
        let lines = try Self.forwarded("""
            console.error(new TypeError("boom-42"));
            try { null.x } catch (err) { console.error("caught", err) }
            """)
        let text = lines.joined(separator: "\n")
        #expect(lines.count == 2, "two calls, two lines: \(text.prefix(300))")
        #expect(text.contains("TypeError: boom-42"), "the error lost its name and message: \(text.prefix(300))")
        #expect(text.contains("caught TypeError"), "a caught error logged with a label lost its message: \(text.prefix(300))")
    }

    @Test("objects still stringify, and a cycle falls back to its String form")
    func objectsStillFormat() throws {
        let lines = try Self.forwarded("""
            console.log({ a: 1 });
            var c = {}; c.self = c; console.warn(c);
            """)
        #expect(lines == [#"{"a":1}"#, "[object Object]"])
    }
}
