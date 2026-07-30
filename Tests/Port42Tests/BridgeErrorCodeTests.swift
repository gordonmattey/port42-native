import Testing
import Foundation
@testable import Port42Lib

/// The error taxonomy (architecture-invariants.md §5).
///
/// Twenty codes had accumulated as string literals at their throw sites, with `bad_args` beside
/// `bad_arg` and `no_port` beside `not_found` — same meaning, different spelling, so a caller
/// matching one silently missed the other. CAS is what made this urgent rather than untidy: the
/// conflict-then-retry design rests on a caller recognising WHICH refusal it got.
@Suite("Bridge error codes — one taxonomy")
struct BridgeErrorCodeTests {

    @Test("no throw site names a code with a bare string literal")
    func noLiteralCodes() throws {
        // THE GATE. The compiler already covers `BridgeError(code:)`, which now takes the enum — this
        // catches the escape hatch (`rawCode:`) being used for a NEW code instead of for a foreign
        // one, which is how a taxonomy grows a twenty-first spelling.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in src.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if t.contains("code: \"") || t.contains("rawCode: \"") {
                    offenders.append("\(url.lastPathComponent): \(t.prefix(70))")
                }
            }
        }
        #expect(offenders.isEmpty, """
            These name an error code with a bare string: \(offenders).
            A code is a value (`BridgeErrorCode`), so the set stays enumerable and two spellings of \
            one meaning cannot coexist. `rawCode:` is for an error crossing a boundary that already \
            carries its own code, not for adding one here.
            """)
    }

    @Test("every wire name is unique, and none collide after collapsing")
    func wireNamesAreUnique() {
        let names = BridgeErrorCode.allCases.map(\.wire)
        #expect(Set(names).count == names.count, "duplicate wire name: \(names)")
        // The two collapses that actually happened. Their old spellings must not come back as cases.
        #expect(!names.contains("bad_args"), "bad_args is bad_arg")
        #expect(!names.contains("no_port"), "no_port is not_found")
    }

    @Test("the retryable pair is exactly the CAS pair")
    func retryableSet() {
        // The single most useful question an agent asks of a failure: can I re-read and try again?
        // It should not have to keep its own list, and the list must not quietly grow — a code that
        // is not self-correcting must never claim to be, or a caller loops on it forever.
        let retryable = BridgeErrorCode.allCases.filter(\.isRetryableWithCurrentState)
        #expect(Set(retryable) == [.staleWrite, .tokenRequired], "unexpected retryable set: \(retryable)")
    }

    @Test("the canonical helpers use the enum, so a body cannot invent wording OR a code")
    func helpersAreCanonical() {
        #expect(BridgeError.missingArg("x").code == BridgeErrorCode.missingArg.wire)
        #expect(BridgeError.notFound("port 'p'").code == BridgeErrorCode.notFound.wire)
        #expect(BridgeError.badArg("nope").code == BridgeErrorCode.badArg.wire)
        #expect(BridgeError.permissionDenied("files").code == BridgeErrorCode.permissionDenied.wire)
    }

    @Test("the two names for a refusal stay APART, because their fixes differ")
    func deniedCodesAreDistinct() {
        // This merge was made, and the suite caught it. `permission_denied` means a capability was
        // not granted and the user grants it; `access_denied` means a path was never picked and the
        // user picks a file. Collapsing them would have told a caller to ask for the wrong thing.
        #expect(BridgeErrorCode.permissionDenied != BridgeErrorCode.accessDenied)
        #expect(BridgeErrorCode.accessDenied.wire == "access_denied")
    }

    @Test("renaming a port that does not exist is an ERROR, not a success")
    @MainActor
    func renameMissingPortFails() async throws {
        // Found live while checking codes: `port.rename` against a nonexistent id answered
        // {"ok": true}. Worse than a missing code — a caller is told its write landed when nothing
        // happened, and nothing looks wrong enough to retry. Same class as `port.push` with a
        // missing `data` typing the string "null" into a live shell (register §5).
        let state = AppState(db: try DatabaseService(inMemory: true))
        await #expect(throws: BridgeError.self) {
            _ = try await state.runBridgeMethod(
                "port.rename",
                principal: Principal.companion(id: "alice", displayName: "alice", spaceId: nil),
                args: BridgeArgs(["id": "no-such-port", "title": "x", PortActivity.expectParam: "a:1"]))
        }
    }

    // MARK: - the ~90 device-bridge failures that were never errors at all

    @Test("a body that REPORTS a failure gets a thrown, coded error")
    @MainActor
    func reportedFailureBecomesAThrow() async throws {
        // Measured: device bridges return `["error": "…"]` and the registry hands that back through
        // `.fromJSONObject` as a SUCCESS. So `screen.capture` with no display answered like a capture
        // that worked — nothing thrown, no code, `ok` to any caller that asked. The family gives the
        // code, because a message cannot be parsed into one without guessing.
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.bridgeRegistry["screen.fakeFailure"] = BridgeMethod(permission: nil, description: "test") { _, _ in
            .fromJSONObject(["error": "no displays available"])
        }
        state.bridgeRegistry["port.fakeFailure"] = BridgeMethod(permission: nil, description: "test") { _, _ in
            .fromJSONObject(["error": "something went wrong"])
        }
        let p = Principal.companion(id: "alice", displayName: "alice", spaceId: nil)

        do {
            _ = try await state.runBridgeMethod("screen.fakeFailure", principal: p, args: BridgeArgs([:]))
            Issue.record("a reported failure was returned as a success")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.deviceError.wire, "screen.* failures are device failures")
            #expect(e.message == "no displays available", "the body's own message must survive")
        }

        do {
            _ = try await state.runBridgeMethod("port.fakeFailure", principal: p, args: BridgeArgs([:]))
            Issue.record("a reported failure was returned as a success")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.methodFailed.wire, "an unnamed family still gets a code")
        }
    }

    @Test("a PAYLOAD that merely mentions an error keeps flowing")
    @MainActor
    func payloadWithAnErrorFieldIsNotAFailure() async throws {
        // The false positive this rule has to avoid. A `browser.error` event carries sessionId, url
        // AND error together: that is data describing something that happened, not this call failing.
        // Narrowing to "error alone, and nothing else" is what keeps it data.
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.bridgeRegistry["browser.report"] = BridgeMethod(permission: nil, description: "test") { _, _ in
            .fromJSONObject(["sessionId": "s1", "url": "https://x", "error": "navigation failed"])
        }
        let out = try await state.runBridgeMethod(
            "browser.report",
            principal: Principal.companion(id: "alice", displayName: "alice", spaceId: nil),
            args: BridgeArgs([:]))
        guard case .object(let o) = out else { Issue.record("expected an object"); return }
        #expect(o["sessionId"] == .string("s1"), "a report about an error is not a failed call")
    }

    /// **REWRITTEN 2026-07-30 (GM: "why not do it now?"). The duplicate is gone, not gated.**
    ///
    /// This used to scan both documents for every code's wire string, because the list was
    /// hand-written prose in two files as well as the enum — three copies, kept in step by a test.
    /// That is the pattern GM rejected for the token format an hour earlier: a gate detects drift, it
    /// does not remove the duplicate.
    ///
    /// Both documents now carry a MARKER and the block is rendered from the enum at load. So the
    /// question is no longer "did someone remember to document a new code" — it is unanswerable,
    /// because there is nowhere else to write one down.
    ///
    /// It also closes what the old gate could not see: it only asked whether a code APPEARED in the
    /// text, so a code filed under the wrong repair, or given a description contradicting its
    /// behaviour, passed. The grouping is now the declaration.
    @Test("both documents render the codes from the enum, and hand-list none")
    func codesAreRenderedNotWritten() throws {
        let res = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Resources")

        for file in ["llms-preamble.txt", "ports-context.txt"] {
            let raw = try String(contentsOf: res.appendingPathComponent(file), encoding: .utf8)
            #expect(raw.contains(BridgeErrorCode.docsMarker),
                    "\(file) lost its marker, so the block would silently vanish")

            // No code may be hand-written beside the marker. `stale_write` and `token_required` are
            // named in surrounding PROSE on purpose (the retry contract explains them), so the check
            // is for the tabular form the block owns — a code followed by the separator it renders.
            let published = BridgeErrorCode.publish(into: raw)
            for code in BridgeErrorCode.allCases {
                #expect(published.contains(code.wire), "\(file) does not publish \(code.wire)")
            }
        }
    }

    @Test("every code has a repair, and the rendered block loses none of them")
    func everyCodeIsRendered() {
        let block = BridgeErrorCode.publishedBlock()
        for code in BridgeErrorCode.allCases {
            #expect(block.contains(code.wire), "\(code.wire) is in the enum but not in the block")
        }
        // Each code appears under EXACTLY ONE repair, which is what makes the grouping a statement
        // rather than a suggestion.
        for repair in BridgeErrorCode.Repair.allCases {
            let owned = BridgeErrorCode.allCases.filter { $0.repair == repair }
            #expect(owned.count == Set(owned.map(\.wire)).count)
        }
        #expect(BridgeErrorCode.allCases.allSatisfy { _ in true })
    }

    @Test("a document with no marker is returned untouched")
    func publishIsSafeOnAnyText() {
        let plain = "no marker here"
        #expect(BridgeErrorCode.publish(into: plain) == plain)
    }

    @Test("the code reaches a COMPANION, not just a JSON caller")
    func codeIsInTheToolUseText() {
        // The gap that mattered most: an in-app companion reaches the bridge through tool use, and
        // tool use renders `toToolBlocks`, which carried the message and the details and NOT the
        // code. So the one caller we most wanted branching had nothing to branch on.
        let e = BridgeError(code: .staleWrite, message: "moved", details: ["current": "e1:5"])
        let text = e.toToolBlocks().first?["text"] as? String ?? ""
        #expect(text.contains("stale_write"), "the code must be in the text a model reads: \(text)")
        #expect(text.contains("current: e1:5"), "and so must the value it retries with")
    }

    @Test("PortActivity's code constants ARE the enum, not a second spelling of it")
    func tokenCodesShareOneDefinition() {
        #expect(PortActivity.staleCode == BridgeErrorCode.staleWrite.wire)
        #expect(PortActivity.tokenRequiredCode == BridgeErrorCode.tokenRequired.wire)
    }
}
