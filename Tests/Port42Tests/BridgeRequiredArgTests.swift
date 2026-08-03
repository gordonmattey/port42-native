import Testing
import Foundation
@testable import Port42Lib

/// **A body must refuse what its own schema calls required** (2026-07-31).
///
/// Register §5's class again, at the argument seam. `port.push` declared `data` required in its own
/// `inputSchema` and then defaulted it anyway (`args.any("data") ?? NSNull()`), so a push sent with
/// the wrong param name (`text`, not `data`) returned `{"ok":true}` sixty times and typed the string
/// `null` into GM's live shell each time. A terminal is a SHELL: a malformed call became text at a
/// prompt, and `ok:true` meant no caller could detect it.
///
/// **Why the existing gate did not catch it.** `BridgeParamConsistencyTests` B1 asserts that every
/// schema-required property is READ by the body. `args.any("data")` is a read, so it passed. The
/// invariant nobody had stated is that a required property must be read by an accessor that can
/// REFUSE. That is B4, and it lives in `BridgeParamConsistencyTests` beside its siblings.
///
/// **Why it mattered beyond one verb.** R5 makes a CAS token mandatory on every write. A write verb
/// whose body cannot fail on a missing required argument would not have failed on a missing `expect`
/// token either, which is the one place R5 needs it non-optional.
///
/// These tests invoke `method.run` DIRECTLY rather than going through `runBridgeMethod`. The
/// dispatcher checks liveness before the body (`applyWriteSideEffects`), so a headless push would be
/// refused with `no_surface` before argument validation was ever reached, and the test would pass
/// against a body that still defaulted. Calling the body is what actually pins the body's contract.
@Suite("A required argument is refused, not defaulted")
@MainActor
struct BridgeRequiredArgTests {

    func world() throws -> AppState {
        AppState(db: try DatabaseService(inMemory: true))
    }

    func principal() -> Principal {
        Principal.companion(id: "tester", displayName: "tester", spaceId: nil)
    }

    func call(_ state: AppState, _ method: String, _ args: [String: Any]) async throws -> BridgeValue {
        guard let m = state.bridgeRegistry[method] else {
            throw BridgeError(code: .unknownMethod, message: method)
        }
        return try await m.run(principal(), BridgeArgs(args))
    }

    /// The wire code a call actually failed with, or nil if it succeeded. `BridgeError.code` is the
    /// wire string, so the enum is compared through `.wire` rather than by case.
    func failureCode(_ state: AppState, _ method: String, _ args: [String: Any]) async -> String? {
        do { _ = try await call(state, method, args); return nil }
        catch let e as BridgeError { return e.code }
        catch { return nil }
    }

    // MARK: - port.push · the reported bug

    @Test("port.push with data ABSENT is refused, and refused before it touches the world")
    func pushMissingDataRefused() async throws {
        let state = try world()
        // A deliberately bogus id. If the body validated its arguments only AFTER resolving the
        // target, this would fail with `not_found` and the real defect would still be live for every
        // caller who named a port that does exist. Arguments are checked first, so the code is
        // `missing_arg` even though the port is fictional.
        let code = await failureCode(state, "port.push", ["id": "no-such-port"])
        #expect(code == BridgeErrorCode.missingArg.wire)
    }

    @Test("port.push with the WRONG param name is refused — the exact call from the field report")
    func pushWrongParamNameRefused() async throws {
        let state = try world()
        // GM sent `text` instead of `data`. Sixty times, each answering ok:true, each typing `null`.
        let code = await failureCode(state, "port.push", ["id": "no-such-port", "text": "ls\n"])
        #expect(code == BridgeErrorCode.missingArg.wire)
    }

    @Test("port.push with an EMPTY STRING is a legitimate payload, not a missing argument")
    func pushEmptyStringIsNotMissing() async throws {
        let state = try world()
        // The over-eager fix refuses this. An empty string is a real thing to send a port, so the
        // check must be about PRESENCE and not about emptiness. It gets past validation and then
        // fails on the fictional port, which is the proof it got past validation.
        let code = await failureCode(state, "port.push", ["id": "no-such-port", "data": ""])
        #expect(code == BridgeErrorCode.notFound.wire)
    }

    @Test("port.push with an explicit JSON null is PRESENT, so it is not a missing argument")
    func pushExplicitNullIsPresent() async throws {
        let state = try world()
        // This is the distinction option B rests on. An absent key and a key holding an explicit
        // null are different acts, and `BridgeArgs` can tell them apart: the positional initializer
        // only assigns keys for supplied indices, while a JSON/JS null arrives as NSNull under a
        // present key. Present, so not `missing_arg`.
        let code = await failureCode(state, "port.push", ["id": "no-such-port", "data": NSNull()])
        #expect(code != BridgeErrorCode.missingArg.wire)
    }

    // MARK: - notify.send · the same class, quieter

    @Test("notify.send with body ABSENT is refused rather than sending an empty notification")
    func notifyMissingBodyRefused() async throws {
        let state = try world()
        // Was `args.string("body") ?? ""`. Schema says required; the body shipped an empty one.
        let code = await failureCode(state, "notify.send", ["title": "hello"])
        #expect(code == BridgeErrorCode.missingArg.wire)
    }

    // MARK: - space.setWorkingDirectory · option B, presence decides

    @Test("setWorkingDirectory with path ABSENT is refused and does NOT clear the directory")
    func setWorkingDirectoryMissingPathRefused() async throws {
        let state = try world()
        state.createSpace(name: "demo")
        let id = state.spaces.first(where: { $0.name == "demo" })!.id
        #expect(state.setSpaceWorkingDirectory("/tmp", spaceId: id))

        // The defect: `args.string("path")` yielded nil for an omitted key, went straight into
        // `setSpaceWorkingDirectory(nil)`, and CLEARED the space's working directory while
        // answering `{"ok": true}`. Every terminal created in that space afterwards silently fell
        // back to home. A malformed call must never be able to destroy state.
        let code = await failureCode(state, "space.setWorkingDirectory", ["space_id": id])
        #expect(code == BridgeErrorCode.missingArg.wire)
        #expect(state.spaces.first(where: { $0.id == id })?.workingDirectory == "/tmp",
                "a refused call must leave the working directory untouched")
    }

    @Test("setWorkingDirectory with an explicit null CLEARS — the deliberate act, spelled out")
    func setWorkingDirectoryExplicitNullClears() async throws {
        let state = try world()
        state.createSpace(name: "demo")
        let id = state.spaces.first(where: { $0.name == "demo" })!.id
        #expect(state.setSpaceWorkingDirectory("/tmp", spaceId: id))

        // Option B (GM, 2026-07-31): one verb, and PRESENCE decides. Clearing stays reachable over
        // the API, matching the UI's own two acts ("Choose…" and "Clear (use home)"), but it now
        // requires the caller to say null rather than to say nothing.
        _ = try await call(state, "space.setWorkingDirectory", ["space_id": id, "path": NSNull()])
        #expect(state.spaces.first(where: { $0.id == id })?.workingDirectory == nil)
    }

    @Test("setWorkingDirectory with an empty string also clears, as it already did")
    func setWorkingDirectoryEmptyStringClears() async throws {
        let state = try world()
        state.createSpace(name: "demo")
        let id = state.spaces.first(where: { $0.name == "demo" })!.id
        #expect(state.setSpaceWorkingDirectory("/tmp", spaceId: id))

        // `Space.normalizeWorkingDirectory` has always folded "" to nil. Pinned so the presence
        // check does not accidentally change what a value MEANS while changing what is required.
        _ = try await call(state, "space.setWorkingDirectory", ["space_id": id, "path": ""])
        #expect(state.spaces.first(where: { $0.id == id })?.workingDirectory == nil)
    }

    @Test("setWorkingDirectory with a real path still sets it")
    func setWorkingDirectorySetsPath() async throws {
        let state = try world()
        state.createSpace(name: "demo")
        let id = state.spaces.first(where: { $0.name == "demo" })!.id

        _ = try await call(state, "space.setWorkingDirectory", ["space_id": id, "path": "/tmp"])
        #expect(state.spaces.first(where: { $0.id == id })?.workingDirectory == "/tmp")
    }
}
