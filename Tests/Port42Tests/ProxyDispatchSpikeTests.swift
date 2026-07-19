import Testing
import Foundation
import JavaScriptCore
@testable import Port42Lib

// MARK: - ProxyDispatchSpikeTests (Spike C)
//
// The last de-risk before the big-bang: can a generic `window.port42` Proxy dispatch
// `port42.a.b(...args)` to the same `call(canonical, args)` the hand-written literal produces? If so,
// the ~240-line literal (PortBridge.swift:1521) can be deleted and replaced by the Proxy + a small
// carve-out shim.
//
// Method: extract the REAL literal from source, evaluate it in a JSContext where `call` records
// (method, args) instead of posting to the host, and diff the recording against a candidate Proxy for
// a table of invocations. Three claims:
//   1. plain platform/device methods dispatch identically (fully-specified args, so the literal's
//      opts-defaulting doesn't diverge),
//   2. service surfaces route through the derived name-map to canonical (creases.* -> crease.*),
//   3. the non-generic members are carved out (machinery `_*`, event `on`, client-only `port.resize`,
//      streaming ai.complete/companions.invoke) — the Proxy handles them, never a generic call().

@Suite("Proxy dispatch (Spike C) — generic Proxy vs the window.port42 literal")
struct ProxyDispatchSpikeTests {

    enum Err: Error { case markerNotFound }

    /// The real `window.port42 = {...}` object literal, lifted from PortBridge.swift source and rebound
    /// as `var port42 = {...}` so it evaluates standalone.
    static func literalObjectJS() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Sources/Port42Lib/Services/PortBridge.swift").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        guard let r1 = text.range(of: "window.port42 = ") else { throw Err.markerNotFound }
        let after = text[r1.upperBound...]
        guard let r2 = after.range(of: "\n    })();") else { throw Err.markerNotFound }
        return "var port42 = " + after[..<r2.lowerBound]
    }

    /// A JSContext whose `call` records into `__calls`, with browser globals stubbed.
    static func makeContext() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, exc in Issue.record("JS exception: \(exc?.toString() ?? "unknown")") }
        ctx.evaluateScript("""
        var __calls = [];
        var _callId = 0, _pending = {}, _tokenCallbacks = {}, _listeners = {}, _statusCallbacks = [], _connected = true;
        var window = { webkit: { messageHandlers: { port42: { postMessage: function(){} }, portHeight: { postMessage: function(){} } } }, innerWidth: 600, innerHeight: 400, addEventListener: function(){} };
        var document = { body: { style: {} } };
        function call(method, args) { __calls.push({ method: method, args: args || [] }); var p = { then: function(cb){ return p; } }; return p; }
        """)
        return ctx
    }

    /// The candidate generic Proxy. Name-map from the manifests (creases/engravings/files); carve-outs
    /// for machinery, events, client-only, and streaming.
    static let proxyJS = """
    var __alias = { 'creases.read':'crease.read','creases.write':'crease.write','creases.touch':'crease.touch','creases.forget':'crease.forget','engravings.read':'engrave.read','engravings.write':'engrave.write','engravings.touch':'engrave.touch','engravings.forget':'engrave.forget','files.read':'fs.read','files.write':'fs.write','files.pick':'fs.pick' };
    var __special = { '_resolve':1,'_reject':1,'_tokenCallback':1,'_emit':1,'_heartbeat':1,'on':1,'connection':1,'viewport':1 };
    var __carve = { 'ai.complete':1,'ai.cancel':1,'companions.invoke':1,'port.resize':1 };
    var port42 = new Proxy({}, { get: function(t, ns) {
      if (typeof ns !== 'string') return undefined;
      if (__special[ns]) return function(){ return '__machinery__'; };
      return new Proxy({}, { get: function(u, method) {
        if (typeof method !== 'string') return undefined;
        var full = ns + '.' + method;
        if (__carve[full] || method === 'on' || method === 'onFileDrop') return function(){ return '__carveout__'; };
        return function() { return call(__alias[full] || full, Array.prototype.slice.call(arguments)); };
      }});
    }});
    """

    /// Run an invocation, return the recorded calls as "method args-json" strings.
    static func record(_ ctx: JSContext, _ invocation: String) -> [String] {
        ctx.evaluateScript("__calls = [];")
        ctx.evaluateScript(invocation)
        let json = ctx.evaluateScript("JSON.stringify(__calls)")?.toString() ?? "[]"
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.map { c in
            let m = c["method"] as? String ?? ""
            let a = (try? JSONSerialization.data(withJSONObject: c["args"] ?? [], options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return "\(m) \(a)"
        }
    }

    @Test("generic Proxy dispatches platform + device methods identically to the literal")
    func plainDispatchMatchesLiteral() throws {
        let lit = Self.makeContext(); lit.evaluateScript(try Self.literalObjectJS())
        let prox = Self.makeContext(); prox.evaluateScript(Self.proxyJS)

        // Fully-specified args, so the literal's `opts || {}` / `n || 20` defaulting does not diverge
        // from the Proxy's raw pass-through (that divergence is a deliberate, body-defaulted change).
        let invocations = [
            "port42.user.get()",
            "port42.space.current()",
            "port42.space.list()",
            "port42.messages.send('hi','space1')",
            "port42.messages.recent(5)",
            "port42.companions.list()",
            "port42.companions.get('c1')",
            "port42.port.getHtml('p1', 3)",
            "port42.port.getHtml('p1')",
            "port42.port.update('p1','<html>')",
            "port42.port.rename('p1','Title')",
            "port42.port.patch('p1','a','b')",
            "port42.port.manage('p1','focus')",
            "port42.port.move('p1',10,20)",
            "port42.ports.list({capabilities:['terminal']})",
            "port42.storage.set('k','v',{scope:'global'})",
            "port42.storage.get('k',{})",
            "port42.storage.delete('k',{})",
            "port42.clipboard.read()",
            "port42.clipboard.write('text')",
            "port42.screen.displays()",
            "port42.screen.capture({scale:1})",
            "port42.terminal.exec('ls',{cwd:'/'})",
            "port42.automation.runAppleScript('say hi',{timeout:5})",
            "port42.notify.send('t','b',{})",
            "port42.fold.read()",
            "port42.position.set('read',{stance:'x'})",
        ]

        var mismatches: [String] = []
        for inv in invocations {
            let l = Self.record(lit, inv), p = Self.record(prox, inv)
            if l != p { mismatches.append("\(inv)\n  literal: \(l)\n  proxy:   \(p)") }
        }
        let report = "proxy differs from literal on plain dispatch:\n" + mismatches.joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(report)")
    }

    @Test("service surfaces route through the derived name-map to canonical")
    func nameMapRoutes() throws {
        let prox = Self.makeContext(); prox.evaluateScript(Self.proxyJS)
        #expect(Self.record(prox, "port42.creases.read()").first == "crease.read []")
        #expect(Self.record(prox, "port42.engravings.write('fact')").first == "engrave.write [\"fact\"]")
        #expect(Self.record(prox, "port42.creases.forget('id1')").first == "crease.forget [\"id1\"]")
        #expect(Self.record(prox, "port42.files.read('relx')").first == "fs.read [\"relx\"]")
    }

    @Test("the shipped bridge dispatches DSL surface names uniformly; the host resolves them")
    func shippedBridgeUniformSurface() throws {
        // The window.port42 literal is now the generic Proxy. It posts the DSL surface name for BOTH
        // creases.read and creases.write (no per-method hand-correction any more); the host resolves
        // creases.* -> crease.* via resolveBridgeAlias. Before, the literal sent 'creases.read'
        // (resolved nowhere) but hand-corrected 'creases.write' -> 'crease.write' inconsistently.
        let lit = Self.makeContext(); lit.evaluateScript(try Self.literalObjectJS())
        #expect(Self.record(lit, "port42.creases.read()").first == "creases.read []")
        #expect(Self.record(lit, "port42.creases.write('x')").first == "creases.write [\"x\"]")
    }

    @Test("the Proxy carves out machinery, events, client-only, and streaming — no generic call()")
    func carveOutsHandled() throws {
        let prox = Self.makeContext(); prox.evaluateScript(Self.proxyJS)
        // streaming + client-only produce no call() — routed to the shim.
        #expect(Self.record(prox, "port42.ai.complete('hi')").isEmpty)
        #expect(Self.record(prox, "port42.ai.cancel(1)").isEmpty)
        #expect(Self.record(prox, "port42.companions.invoke('id','hi')").isEmpty)
        #expect(Self.record(prox, "port42.port.resize(10,20)").isEmpty)
        // machinery + event handlers exist but are not dispatched.
        #expect(Self.record(prox, "port42._resolve(1,{})").isEmpty)
        #expect(Self.record(prox, "port42.audio.on('level', function(){})").isEmpty)
    }
}
