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

    @Test("every code is PUBLISHED, in both places an agent reads")
    func everyCodeIsDocumented() throws {
        // The lists drifted the moment they were written, because both were hand-typed: five codes
        // (js_error, no_body, no_user, no_messages, not_llm) were in the enum and in neither doc,
        // while the doc claimed "the set is closed". Telling an agent to branch on a closed set and
        // then publishing an incomplete one is worse than publishing nothing.
        //
        // TWO audiences, two files, and both must be complete: `llms-preamble.txt` becomes llms.txt,
        // which a Claude Code session reads; `ports-context.txt` is what a PORT author gets from
        // help(topic:"ports").
        let res = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Resources")
        for file in ["llms-preamble.txt", "ports-context.txt"] {
            let text = try String(contentsOf: res.appendingPathComponent(file), encoding: .utf8)
            let missing = BridgeErrorCode.allCases.map(\.wire).filter { !text.contains($0) }
            #expect(missing.isEmpty, "\(file) does not document: \(missing)")
        }
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
