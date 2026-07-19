import Testing
import Foundation
@testable import Port42Lib

// MARK: - BridgeParamConsistencyTests (Spike B)
//
// The three descriptions of a method's parameters must agree, or a caller sends a key the body never
// reads:
//   1. inputSchema.properties  — what the model / gateway send (named)
//   2. paramNames              — what a positional JS / Proxy call maps to
//   3. the keys the body reads — args.requireString("x") / args.int("x") / args.object("options") ...
//
// This is the invariant the generic JS Proxy depends on (positional → paramNames → named → body) and
// the invariant the tool-use path depends on (schema required props → named → body). The clipboard
// drift (schema "text", body reads "data") was one instance found by hand; this sweeps for the class.
//
// It works by SOURCE SCAN of BridgeMethods.swift: split into register-function segments (so an options
// bag and shared helper reads are scoped to the function that owns them), then per method extract
// paramNames, the schema `required` list, and every `args.<accessor>("key")` the body (and its
// function's shared helpers) reads, plus bag subscript reads (o["x"] / opts["x"]). Asserts:
//   B1 (schema → body): every required schema property is read by the body, or an options bag is present.
//   B2 (paramNames → body): every non-bag paramName is read by the body.
// B3 (schema properties never read, no bag) is reported, not failed.

@Suite("Bridge parameter consistency (Spike B) — schema/paramNames vs body reads")
struct BridgeParamConsistencyTests {

    // A trailing paramName equal to one of these is an options bag: it maps positional args to a dict,
    // so it need not be a key the body reads by that literal name.
    static let bagParamNames: Set<String> = ["options"]

    struct Method {
        let canonical: String
        let paramNames: [String]
        let required: [String]
        let reads: Set<String>   // direct body reads + this function's shared-helper reads + bag subscripts
        let bag: Bool            // the body or its function's helpers consume an options bag
    }

    // MARK: source-scan helpers

    static func matches(_ pattern: String, in s: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: group), in: s).map { String(s[$0]) }
        }
    }

    /// `args.<accessor>("key")` reads (requireString, string, int, double, any, object, array, bool...).
    static func argReads(_ s: String) -> Set<String> {
        Set(matches(#"args\.\w+\(\s*"([^"]+)""#, in: s))
    }

    /// Bag subscript reads: `o["x"]` / `opts["x"]` / `options["x"]` (a value pulled out of an opts dict).
    static func bagSubscriptReads(_ s: String) -> Set<String> {
        Set(matches(#"(?:\bo|\bopts|\boptions)\??\[\s*"([^"]+)"\]"#, in: s))
    }

    static func hasBag(_ s: String) -> Bool {
        s.contains("args.object(") || s.contains("args.dictionary")
    }

    /// paramNames array from a `BridgeMethod(...)` / `BridgeStreamMethod(...)` declaration.
    static func paramNames(_ decl: String) -> [String] {
        guard let inner = matches(#"paramNames:\s*\[([^\]]*)\]"#, in: decl).first else { return [] }
        return matches(#""([^"]+)""#, in: inner)
    }

    /// The `required` list from a method's inputSchema (empty if none, or `[String]()`).
    static func required(_ chunk: String) -> [String] {
        guard let inner = matches(#""required":\s*\[([^\]]*)\]"#, in: chunk).first else { return [] }
        return matches(#""([^"]+)""#, in: inner)
    }

    /// The source files that register bridge methods: the built-ins, plus one file per service module.
    /// A new service module is added here so its methods are consistency-checked too.
    static let registrySources = [
        "Sources/Port42Lib/Services/BridgeMethods.swift",
        "Sources/Port42Lib/Services/BridgeServiceAI.swift",
    ]

    /// Parse every registry method out of the registry source files.
    static func parseMethods() throws -> [Method] {
        let root = URL(fileURLWithPath: #filePath)   // .../Tests/Port42Tests/BridgeParamConsistencyTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try registrySources.flatMap { rel in
            try parseFile(root.appendingPathComponent(rel).path)
        }
    }

    static func parseFile(_ path: String) throws -> [Method] {
        let text = try String(contentsOfFile: path, encoding: .utf8)

        // Segment boundaries: top-level `private/public func …` (nested helpers have no access modifier,
        // so they never start a segment). Each register/build function is one segment.
        let ns = text as NSString
        // Top-level funcs only (column 0). Optional access modifier — a service module's register fn is
        // internal (no modifier) because it's called cross-file; the built-ins' are private/public.
        // Nested helpers are indented, so `^` never matches them.
        let re = try NSRegularExpression(pattern: #"(?m)^(?:(?:private|public|internal) )?func \w+"#)
        let starts = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range.location }
        guard !starts.isEmpty else { return [] }

        var out: [Method] = []
        for (i, start) in starts.enumerated() {
            let end = (i + 1 < starts.count) ? starts[i + 1] : ns.length
            let segment = ns.substring(with: NSRange(location: start, length: end - start))
            guard segment.contains(#"r[""#) else { continue }   // skip funcs with no method entries

            // Split the segment on `r["`: [preamble, method1, method2, ...].
            let parts = segment.components(separatedBy: #"r[""#)
            let preamble = parts[0]
            let helperReads = argReads(preamble)
            let helperBag = hasBag(preamble)

            for part in parts.dropFirst() {
                let chunk = #"r[""# + part
                guard let canonical = matches(#"^r\["([^"]+)"\]"#, in: chunk).first else { continue }
                let reads = argReads(chunk).union(bagSubscriptReads(chunk)).union(helperReads)
                out.append(Method(
                    canonical: canonical,
                    paramNames: paramNames(chunk),
                    required: required(chunk),
                    reads: reads,
                    bag: hasBag(chunk) || helperBag
                ))
            }
        }
        return out
    }

    @Test("Parser finds all registry methods (sanity)")
    func parserCoverage() throws {
        let methods = try Self.parseMethods()
        // Source-scan covers the `r["..."] = BridgeMethod` form. Manifest-declared services (Keeper 12,
        // storage 4) leave the source-scan and are checked by the runtime probe below instead.
        // BridgeMethods.swift: 46 one-shot (38 + tail items 1+2: messages.sendAsCreator,
        // space.switchTo + tail item 9: port.info, port.setTitle, port.setCapabilities, port.close,
        // port.position + tail item 4: rest.call) + companions.invoke = 47. BridgeServiceAI.swift: 3.
        // Total 50.
        #expect(methods.count == 50, "parsed \(methods.count) methods: \(methods.map(\.canonical).sorted())")
    }

    @Test("B1 + B2: every required schema prop and every non-bag paramName is read by the body")
    func paramsAreConsistentWithBody() throws {
        let methods = try Self.parseMethods()
        var violations: [String] = []
        var bagExempted: [String] = []

        for m in methods {
            // B1 — schema required props reach the body.
            for prop in m.required where !m.reads.contains(prop) {
                if m.bag { bagExempted.append("\(m.canonical): required '\(prop)' not directly read (options bag present)") }
                else { violations.append("B1 \(m.canonical): required schema prop '\(prop)' is never read by the body (reads: \(m.reads.sorted()))") }
            }
            // B2 — non-bag paramNames reach the body.
            for name in m.paramNames where !Self.bagParamNames.contains(name) && !m.reads.contains(name) {
                violations.append("B2 \(m.canonical): paramName '\(name)' is never read by the body (reads: \(m.reads.sorted()))")
            }
        }

        if !bagExempted.isEmpty {
            // Reported, not failed: these are covered by the bag but not directly verifiable by scan.
            let exempt: String = "B1 bag-exempted (verify by hand or behavioral test):\n  " + bagExempted.sorted().joined(separator: "\n  ")
            Issue.record("\(exempt)")
        }
        let report: String = "parameter consistency violations:\n  " + violations.sorted().joined(separator: "\n  ")
        #expect(violations.isEmpty, "\(report)")
    }

    // Manifest-declared services (Keeper) are checked by a RUNTIME probe rather than the source scan:
    // their bodies are bound by canonical name, not written as `r["..."] = BridgeMethod`. The probe
    // invokes each method with an input built from the manifest's `required` props and asserts no
    // argument-shaped error, which catches the clipboard class (a required prop the body never reads)
    // by actually running the body. Keeper is headless (DB-backed), so this runs without hardware.
    @Test("manifest service consistency: every method accepts its required args, no arg error")
    @MainActor
    func manifestServiceConsistency() async throws {
        let world = try makeParityWorld()
        let registry = buildBridgeRegistry(world.state)
        let argCodes: Set<String> = ["bad_arg", "bad_args", "missing_arg"]

        for service in appManifestServices() {
            for method in service.methods {
                let required = (method.inputSchema["required"] as? [String]) ?? []
                var input: [String: Any] = [:]
                for key in required { input[key] = "x" }   // required props here are all strings
                guard let impl = registry[method.canonical] else {
                    Issue.record("\(service.service): method '\(method.canonical)' not in the registry"); continue
                }
                do {
                    _ = try await impl.run(world.principal, BridgeArgs(input))
                } catch let e as BridgeError where argCodes.contains(e.code) {
                    Issue.record("\(method.canonical): arg error on manifest-required input \(input): \(e.code) — \(e.message)")
                } catch {
                    // A non-arg error (not_found on a dummy id, etc.) means the args parsed fine. Acceptable.
                }
            }
        }

        // The dispatch path resolves the DSL surface to canonical (the fix for the broken creases.read /
        // engravings.* calls). bridgeHandles routes through the same resolver every adapter uses.
        #expect(world.state.resolveBridgeAlias("creases.read") == "crease.read")
        #expect(world.state.resolveBridgeAlias("engravings.write") == "engrave.write")
        #expect(world.state.bridgeHandles("creases.read"))
        #expect(world.state.bridgeHandles("engravings.write"))
    }

    @Test("Keeper's declared name-map resolves the DSL surface to canonical")
    @MainActor
    func keeperNameMapResolves() throws {
        let map = keeperManifest().nameMap
        #expect(map["creases.read"] == "crease.read")
        #expect(map["creases.write"] == "crease.write")
        #expect(map["engravings.read"] == "engrave.read")
        #expect(map["engravings.forget"] == "engrave.forget")
        // fold / position surfaces equal their canonical, so they are NOT in the map.
        #expect(map["fold.read"] == nil)
        #expect(map["position.set"] == nil)
        #expect(map.count == 8)
    }
}
