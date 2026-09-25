import Testing
import Foundation
@testable import Port42Lib

/// An argument a method does not declare is refused, not ignored (nautilus Phase 0 step 6).
///
/// Ignoring it is how a wrong answer looked right: `terminal.exec` given an `id` ran on the machine
/// instead of in a terminal (2026-07-31), and `ports.list` was passed an `all_spaces` it does not
/// have on every call of an audit (F13).
@Suite("Bridge declared arguments")
@MainActor
struct BridgeDeclaredArgsTests {

    func run(_ w: ParityWorld, _ method: String, _ args: [String: Any]) async -> BridgeError? {
        do {
            _ = try await w.state.runBridgeMethod(method, principal: .peer(id: "cli", displayName: "cli"),
                                                  args: BridgeArgs(args))
            return nil
        } catch let e as BridgeError { return e } catch { return nil }
    }

    @Test("an undeclared argument is refused, named, and the declared ones are listed")
    func undeclaredRefused() async throws {
        let w = try makeParityWorld()
        let e = await run(w, "ports.list", ["all_spaces": true])
        #expect(e?.code == BridgeErrorCode.badArg.wire)
        #expect(e?.message.contains("'all_spaces'") == true)
        #expect(e?.message.contains("space_id") == true, "the refusal must say what the method does take")
    }

    /// The refusal sits ahead of the permission gate in the dispatcher, so a malformed call never
    /// raises a card. Tested with the permission PRE-GRANTED: without a grant, a regression would
    /// reach the gate and wait for a human who never answers, hanging the suite (found calibrating
    /// this gate). Pre-granted, a regression runs a harmless `true` and fails at once instead.
    @Test("a gated method refuses an undeclared argument instead of running")
    func refusedBeforeRunning() async throws {
        let w = try makeParityWorld()
        do {
            _ = try await w.state.runBridgeMethod("terminal.exec", principal: .peer(id: "cli", displayName: "cli"),
                                                  args: BridgeArgs(["command": "true", "id": "some-port"]),
                                                  pregrant: [.terminal])
            Issue.record("terminal.exec ran with an undeclared `id`")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.badArg.wire)
            #expect(e.message.contains("'id'"))
        }
    }

    @Test("declared arguments pass, and a token is accepted on any method")
    func declaredPass() async throws {
        let w = try makeParityWorld()
        #expect(await run(w, "ports.list", ["space_id": w.principal.spaceId ?? ""]) == nil)
        #expect(await run(w, "ports.list", ["token": "abc:0"]) == nil, "a read ignores a token; it must not refuse it")
    }

    @Test("port JS cannot send an undeclared name: positional args are zipped against the declared ones")
    func positionalIsDeclaredByConstruction() {
        let a = BridgeArgs(positional: ["P", 1, "extra", true], names: ["id"])
        #expect(a.names == ["id"])
    }

    /// The methods whose only declared argument is an opaque `options` bag accept their options flat,
    /// and those keys are not declared anywhere yet, so they are exempt. Pinned so the exemption can
    /// only shrink: declaring a bag's keys removes it from this list, and a NEW open bag fails here.
    @Test("the open option bags are exactly the known ones")
    func openBagsPinned() throws {
        let w = try makeParityWorld()
        var open: Set<String> = []
        for (n, m) in w.registry where DeclaredArgs.isOpenBag(m.declaredArgs) { open.insert(n) }
        for (n, m) in w.state.bridgeStreamRegistry where DeclaredArgs.isOpenBag(m.declaredArgs) { open.insert(n) }
        #expect(open == ["audio.capture", "camera.stream", "fs.pick", "screen.record",
                         "screen.record.start", "screen.stream", "storage.list"])
    }

    /// Declarations stay COMPLETE: every argument a method body reads is declared. Without this, a
    /// body that reads a key its declaration omits would have that key refused by the rule above, and
    /// a working call would break. Source-scanned, because a read is a line of code, not a value.
    @Test("every argument a method body reads is declared")
    func bodiesReadOnlyDeclaredArgs() throws {
        let w = try makeParityWorld()
        var declared: [String: Set<String>] = [:]
        for (n, m) in w.registry { declared[n] = m.declaredArgs }
        for (n, m) in w.state.bridgeStreamRegistry { declared[n] = m.declaredArgs }

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib/Services")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Bridge") && $0.hasSuffix(".swift") }
        let start = try NSRegularExpression(pattern: #"r\["([a-z]+\.[A-Za-z.]+)"\]\s*=\s*Bridge"#)
        let read = try NSRegularExpression(pattern: #"args\.[a-zA-Z]+\("([A-Za-z_]+)"\)"#)
        // A method that takes its options FLAT (`args.object("options") ?? args.dictionary`) reads its
        // keys out of that dictionary, as `o["presentation"]`. Those are argument reads too.
        // `as?` is what makes it a READ of an option; `o["image"]` pattern-matched out of a RESULT is not.
        let bagRead = try NSRegularExpression(pattern: #"\b(?:o|opts|bag)\["([A-Za-z_]+)"\]\s*as\?"#)
        let helpers: [String: Set<String>] = ["senderName(p": ["senderName", "sender_name"],
                                              "targetSpace(p": ["space_id"]]
        var gaps: [String] = []
        var scanned = 0
        for file in files {
            let lines = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
            var i = 0
            while i < lines.count {
                let l = lines[i]
                guard let m = start.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                      let r = Range(m.range(at: 1), in: l) else { i += 1; continue }
                let name = String(l[r])
                var j = i + 1
                while j < lines.count, !lines[j].hasPrefix("    r[\""), !lines[j].hasPrefix("}"),
                      !lines[j].hasPrefix("private func"), !lines[j].hasPrefix("func") { j += 1 }
                let body = lines[i..<j].joined(separator: "\n")
                var reads = Set(read.matches(in: body, range: NSRange(body.startIndex..., in: body))
                    .compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } })
                for (h, keys) in helpers where body.contains(h) { reads.formUnion(keys) }
                if body.contains("args.dictionary") {
                    reads.formUnion(bagRead.matches(in: body, range: NSRange(body.startIndex..., in: body))
                        .compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } })
                }
                if let d = declared[name], !DeclaredArgs.isOpenBag(d) {
                    scanned += 1
                    let missing = reads.subtracting(d).subtracting([PortActivity.expectParam, "options"])
                    if !missing.isEmpty { gaps.append("\(name) reads \(missing.sorted()) without declaring them") }
                }
                i = j
            }
        }
        #expect(scanned > 40, "the scan must actually see the methods (saw \(scanned))")
        #expect(gaps.isEmpty, "\(gaps.joined(separator: "; "))")
    }
}
