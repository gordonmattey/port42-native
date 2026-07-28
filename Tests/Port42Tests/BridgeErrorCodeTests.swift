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

    @Test("PortActivity's code constants ARE the enum, not a second spelling of it")
    func tokenCodesShareOneDefinition() {
        #expect(PortActivity.staleCode == BridgeErrorCode.staleWrite.wire)
        #expect(PortActivity.tokenRequiredCode == BridgeErrorCode.tokenRequired.wire)
    }
}
