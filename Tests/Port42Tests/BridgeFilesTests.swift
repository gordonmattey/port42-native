import Testing
import Foundation
@testable import Port42Lib

// Phase 1, batch 6: files. Canonical model is the data-dir sandbox — relative paths only, resolved
// under BridgeFilePaths.dataDir; absolute paths route to the picker (fs.pick, live-only). Serialized
// because the tests swap the global data-dir hook to an isolated temp dir.

@Suite("Bridge — files", .serialized)
struct BridgeFilesTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(w.principal, BridgeArgs(input))
    }

    /// Run a body with the data dir pointed at a fresh temp directory, cleaned up after.
    @MainActor
    func withTempDataDir(_ body: (ParityWorld) async throws -> Void) async throws {
        let original = BridgeFilePaths.dataDir
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("p42-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        BridgeFilePaths.dataDir = tmp
        defer {
            BridgeFilePaths.dataDir = original
            try? FileManager.default.removeItem(atPath: tmp)
        }
        try await body(try makeParityWorld())
    }

    @Test("write then read round-trips text")
    @MainActor
    func writeRead() async throws {
        try await withTempDataDir { w in
            let wrote = try await call(w, "fs.write", ["path": "notes/a.txt", "data": "hello"])
            #expect(wrote == .object(["ok": .bool(true)]))
            let read = try await call(w, "fs.read", ["path": "notes/a.txt"])
            #expect(read == .object(["data": .string("hello")]))
        }
    }

    @Test("base64 round-trips bytes")
    @MainActor
    func base64() async throws {
        try await withTempDataDir { w in
            let b64 = Data("bytes".utf8).base64EncodedString()
            _ = try await call(w, "fs.write", ["path": "b.bin", "data": b64, "encoding": "base64"])
            let read = try await call(w, "fs.read", ["path": "b.bin", "encoding": "base64"])
            #expect(read == .object(["data": .string(b64)]))
        }
    }

    @Test("mkdir then list shows the entry")
    @MainActor
    func mkdirList() async throws {
        try await withTempDataDir { w in
            _ = try await call(w, "fs.mkdir", ["path": "sub"])
            _ = try await call(w, "fs.write", ["path": "sub/x.txt", "data": "1"])
            let listed = try await call(w, "fs.list", ["path": "sub"])
            #expect(listed == .object(["items": .array([.string("x.txt")])]))
        }
    }

    @Test("absolute paths are rejected (they belong to the picker)")
    @MainActor
    func absoluteRejected() async throws {
        try await withTempDataDir { w in
            await #expect(throws: BridgeError.self) { _ = try await call(w, "fs.read", ["path": "/etc/hosts"]) }
        }
    }

    @Test("path traversal out of the sandbox is blocked")
    @MainActor
    func traversalBlocked() async throws {
        try await withTempDataDir { w in
            await #expect(throws: BridgeError.self) { _ = try await call(w, "fs.read", ["path": "../../secret"]) }
        }
    }

    @Test("reading a missing file throws io, not a silent nil")
    @MainActor
    func missingThrows() async throws {
        try await withTempDataDir { w in
            await #expect(throws: BridgeError.self) { _ = try await call(w, "fs.read", ["path": "nope.txt"]) }
        }
    }

    @Test("fs.* carry the .filesystem permission requirement")
    @MainActor
    func permission() async throws {
        try await withTempDataDir { w in
            for m in ["fs.read", "fs.write", "fs.list", "fs.mkdir"] {
                #expect(w.registry[m]?.permission == .filesystem)
            }
        }
    }
}

// Tail item 7: the picked-path family wired. fs.pick joins the registry (panels are port UX, not an
// LLM tool) and grants land on an AppState store KEYED BY PRINCIPAL id (the Phase-3 seam), not on a
// per-port FileBridge instance. fs.read/fs.write accept an absolute path only when THIS principal
// picked it; anyone else gets access_denied. The sandbox (relative-path) semantics above are
// untouched. The live half (a real NSOpenPanel through a port) runs in Port42Dev with GM.

@Suite("Bridge — files (picked paths)", .serialized)
struct BridgeFilesPickedTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical], "missing \(canonical)")
        return try await method.run(w.principal, BridgeArgs(input))
    }

    @MainActor
    func errorCode(_ w: ParityWorld, _ canonical: String, _ input: [String: Any]) async throws -> String {
        do {
            _ = try await call(w, canonical, input)
            return "NO_ERROR"
        } catch let e as BridgeError {
            return e.code
        }
    }

    /// A real temp file OUTSIDE the sandbox, to stand in for a picker-chosen path.
    func makeTempFile(_ content: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("p42-picked-\(UUID().uuidString).txt")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("the family is wired and fs.pick is registered, gated, and not a tool")
    @MainActor
    func wiring() throws {
        let w = try makeParityWorld()
        let pick = try #require(w.registry["fs.pick"], "fs.pick must join the registry")
        #expect(pick.permission == .filesystem)
        #expect(!pick.toolExposed, "the picker is port UX, not an LLM tool")
        for m in ["fs.pick", "fs.read", "fs.write", "fs.list", "fs.mkdir"] {
            #expect(try #require(w.registry[m]).wired, "\(m) must be wired")
        }
    }

    @Test("a picked absolute path is readable and writable by the granting principal")
    @MainActor
    func pickedRoundTrip() async throws {
        let w = try makeParityWorld()
        let path = try makeTempFile("picked contents")
        defer { try? FileManager.default.removeItem(atPath: path) }
        w.state.grantPickedPath(path, to: w.principal.id)

        let read = try await call(w, "fs.read", ["path": path])
        guard case let .object(o) = read, case let .string(data)? = o["data"] else {
            Issue.record("fs.read of a picked path should return {data}")
            return
        }
        #expect(data == "picked contents")

        _ = try await call(w, "fs.write", ["path": path, "data": "rewritten"])
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "rewritten")
    }

    @Test("an un-picked absolute path is access_denied")
    @MainActor
    func unpickedDenied() async throws {
        let w = try makeParityWorld()
        let path = try makeTempFile("secret")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try await errorCode(w, "fs.read", ["path": path]) == "access_denied")
        #expect(try await errorCode(w, "fs.write", ["path": path, "data": "x"]) == "access_denied")
    }

    @Test("a grant belongs to ONE principal — another caller is denied")
    @MainActor
    func principalIsolation() async throws {
        let w = try makeParityWorld()
        let path = try makeTempFile("mine")
        defer { try? FileManager.default.removeItem(atPath: path) }
        w.state.grantPickedPath(path, to: "some-other-principal")
        #expect(try await errorCode(w, "fs.read", ["path": path]) == "access_denied")
        #expect(try await errorCode(w, "fs.write", ["path": path, "data": "x"]) == "access_denied")
    }
}
