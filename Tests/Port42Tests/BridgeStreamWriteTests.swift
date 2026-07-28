import Testing
import Foundation
@testable import Port42Lib

/// I2 · C5 — a streaming write verb cannot escape the seam.
///
/// Before C5 the streaming registry had no `writesTarget` at all, so a streaming method that wrote to
/// a port would have moved no token, checked no CAS and recorded no presence, and nothing would have
/// reported it. Nothing escaped in practice, because all three streaming methods happen to be reads.
/// "Happens to be" is exactly the kind of property this seam replaces with a structural one, and it
/// is how the six ad-hoc input hooks accumulated in the first place.
///
/// These register a REAL streaming write verb in the registry and dispatch it, rather than asserting
/// something about the source. A source scan would only prove the field exists; this proves the
/// dispatcher acts on it.
@Suite("Bridge — streaming writes go through the seam (I2 C5)")
@MainActor
struct BridgeStreamWriteTests {

    func makeWorld() throws -> (AppState, String) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let id = "stream-target-1"
        _ = state.portWindows.registerInlinePort(
            id: id, html: "<html><body>hi</body></html>",
            spaceId: nil, createdBy: nil, title: "t", anchorMessageId: nil)
        let udid = state.portWindows.panels.first(where: { $0.id == id })!.udid
        return (state, udid)
    }

    /// A streaming verb that declares it writes to the port named by `id`.
    func registerStreamingWrite(_ state: AppState, name: String = "test.streamWrite") {
        state.bridgeStreamRegistry[name] = BridgeStreamMethod(
            permission: nil, paramNames: ["id"], writesTarget: "id",
            description: "test-only streaming write") { _, _, yield in
                yield("chunk")
                return .object(["ok": .bool(true)])
            }
    }

    @Test("a streaming write MOVES the token, exactly as the one-shot path does")
    func streamingWriteBumps() async throws {
        let (state, udid) = try makeWorld()
        registerStreamingWrite(state)
        let before = state.portInput.seq(for: udid)

        _ = try await state.runBridgeStream(
            "test.streamWrite", principal: .peer(id: "p", displayName: "p"),
            args: BridgeArgs(["id": udid, PortActivity.expectParam: state.portInput.token(for: udid)]),
            yield: { _ in })

        #expect(state.portInput.seq(for: udid) == before + 1,
                "a streaming write must count; before C5 the streaming registry had no writesTarget")
    }

    @Test("a streaming write is REFUSED against a stale token")
    func streamingWriteHonoursCAS() async throws {
        let (state, udid) = try makeWorld()
        registerStreamingWrite(state)

        let composed = state.portInput.token(for: udid)
        // Someone else writes, moving the port past what our caller read.
        _ = try await state.runBridgeStream(
            "test.streamWrite", principal: .peer(id: "other", displayName: "other"),
            args: BridgeArgs(["id": udid, PortActivity.expectParam: state.portInput.token(for: udid)]),
            yield: { _ in })

        await #expect(throws: BridgeError.self) {
            _ = try await state.runBridgeStream(
                "test.streamWrite", principal: .peer(id: "p", displayName: "p"),
                args: BridgeArgs(["id": udid, PortActivity.expectParam: composed]), yield: { _ in })
        }
    }

    @Test("a refused streaming write does NOT move the token")
    func refusedStreamingWriteLeavesTheTokenAlone() async throws {
        let (state, udid) = try makeWorld()
        registerStreamingWrite(state)
        let stale = state.portInput.token(for: udid)
        _ = try await state.runBridgeStream(
            "test.streamWrite", principal: .peer(id: "other", displayName: "other"),
            args: BridgeArgs(["id": udid, PortActivity.expectParam: state.portInput.token(for: udid)]),
            yield: { _ in })
        let afterOther = state.portInput.seq(for: udid)

        _ = try? await state.runBridgeStream(
            "test.streamWrite", principal: .peer(id: "p", displayName: "p"),
            args: BridgeArgs(["id": udid, PortActivity.expectParam: stale]), yield: { _ in })

        #expect(state.portInput.seq(for: udid) == afterOther,
                "CAS is checked BEFORE the bump, or a refused write invalidates the very token it lost to")
    }

    @Test("a streaming write records PRESENCE, so the chrome names its driver")
    func streamingWriteRecordsPresence() async throws {
        let (state, udid) = try makeWorld()
        registerStreamingWrite(state)

        _ = try await state.runBridgeStream(
            "test.streamWrite", principal: .peer(id: "peer-7", displayName: "Claude Code"),
            args: BridgeArgs(["id": udid, PortActivity.expectParam: state.portInput.token(for: udid)]),
            yield: { _ in })

        #expect(state.portInput.driver(of: udid, now: Date())?.name == "Claude Code")
    }

    @Test("a streaming READ moves nothing")
    func streamingReadIsInert() async throws {
        let (state, udid) = try makeWorld()
        // No writesTarget: a read.
        state.bridgeStreamRegistry["test.streamRead"] = BridgeStreamMethod(
            permission: nil, paramNames: ["id"],
            description: "test-only streaming read") { _, _, _ in .object([:]) }
        let before = state.portInput.seq(for: udid)

        _ = try await state.runBridgeStream(
            "test.streamRead", principal: .peer(id: "p", displayName: "p"),
            args: BridgeArgs(["id": udid, PortActivity.expectParam: state.portInput.token(for: udid)]),
            yield: { _ in })

        #expect(state.portInput.seq(for: udid) == before, "a read must not move the token")
        #expect(state.portInput.driver(of: udid, now: Date()) == nil, "a read must not claim presence")
    }

    @Test("`expect` is injected centrally into streaming writes, not per declaration")
    func expectIsInjectedForStreamingWrites() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        // Every registered streaming method that declares a write must accept `expect`, because the
        // registry builder maps it in once. A verb added tomorrow gets CAS by construction.
        for (name, m) in state.bridgeStreamRegistry where m.writesTarget != nil {
            #expect(m.paramNames.contains(PortActivity.expectParam),
                    "streaming write '\(name)' does not accept `expect`; the central injection missed it")
        }
    }
}
