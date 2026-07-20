import Testing
import Foundation
@testable import Port42Lib

// The 2026-07-19 prod-kill fixes. A full-suite test run walked completeSetup into
// configureSyncIfNeeded: the test process's GatewayProcess was "not running" while the REAL app's
// gateway held :4242, so killProcessOnPort(4242) fired — and `lsof -ti tcp:PORT` lists every
// process with ANY socket on the port, so the SIGTERM hit the listener AND its clients: the
// running production app, its companions, and ngrok. Two fixes, one gate each:
//   A. killProcessOnPort must kill the LISTENer only (`-sTCP:LISTEN`) — gated fail-then-pass here
//      with scratch child processes on a scratch port.
//   B. a test process must never manage real infrastructure at all (no gateway spawn, no port
//      reclaim, no sync connect, no ngrok autostart). The failing state of this gate was recorded
//      LIVE by the incident itself; deliberately re-running the pre-guard path would kill the
//      production app again, so the gate runs post-fix only and #requires the detection primitive
//      BEFORE touching the dangerous path.

@Suite("Gateway reclaim safety")
struct GatewayReclaimSafetyTests {

    /// Spawn a python child that LISTENs on the port, accepts one connection, then idles.
    func spawnListener(port: Int) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", """
            import socket, time
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", \(port)))
            s.listen(1)
            c, _ = s.accept()
            time.sleep(60)
            """]
        try p.run()
        return p
    }

    /// Spawn a python child that connects to the port as a CLIENT (retrying until the listener is
    /// up), then idles. This is the stand-in for the production app / companions / ngrok.
    func spawnClient(port: Int) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", """
            import socket, time
            s = socket.socket()
            for _ in range(100):
                try:
                    s.connect(("127.0.0.1", \(port)))
                    break
                except OSError:
                    time.sleep(0.1)
            time.sleep(60)
            """]
        try p.run()
        return p
    }

    /// PIDs lsof reports for the port (any TCP state), used to wait for the fixture to be live.
    func pidsOnPort(_ port: Int) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").map(String.init)
    }

    @Test("killProcessOnPort kills the listener only, never the port's clients")
    @MainActor
    func killsListenerOnly() async throws {
        let port = Int.random(in: 40000...49999)
        let listener = try spawnListener(port: port)
        let client = try spawnClient(port: port)
        defer {
            if listener.isRunning { listener.terminate() }
            if client.isRunning { client.terminate() }
        }

        // Wait until both the listener and the established client connection are visible to lsof
        // (the connection shows one pid per side plus the listen socket).
        var live = false
        for _ in 0..<50 {
            if Set(pidsOnPort(port)).count >= 2 { live = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try #require(live, "fixture never came up: listener + connected client on \(port)")

        let w = try makeParityWorld()
        w.state.killProcessOnPort(port)

        // The listener must die...
        var listenerDied = false
        for _ in 0..<30 {
            if !listener.isRunning { listenerDied = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(listenerDied, "the process LISTENing on the port must be killed")
        // ...and the client must survive. Pre-fix, `lsof -ti tcp:PORT` listed it too and it got
        // SIGTERMed — that is exactly how the production app died on 2026-07-19.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.isRunning, "a process merely CONNECTED to the port must never be killed")
    }

    @Test("a test process never manages real infrastructure")
    @MainActor
    func testHarnessGuard() throws {
        // The canary comes first: if detection does not hold, STOP — proceeding would let
        // completeSetup reclaim the real gateway port (the incident).
        try #require(AppState.isTestProcess, "test-harness detection must hold in this process")

        // Second canary (found 2026-07-19): the boot path also rewrites the USER'S REAL
        // instruction files (~/.claude/CLAUDE.md etc.) via InstructionService.refreshInstalled —
        // a test run must never touch them. Snapshot mtimes before, compare after.
        let realFiles = [".claude/CLAUDE.md", ".gemini/GEMINI.md", ".codex/AGENTS.md"]
            .map { (NSHomeDirectory() as NSString).appendingPathComponent($0) }
        func mtimes() -> [Date?] {
            realFiles.map { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        }
        let before = mtimes()

        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: "Guard")
        try db.saveUser(user)
        state.currentUser = user
        state.completeSetup(displayName: "Guard")

        #expect(state.sync.gatewayURL == nil, "a test process must not configure sync")
        #expect(!state.sync.isConnected, "a test process must not connect to a gateway")
        #expect(!GatewayProcess.shared.isRunning, "a test process must not spawn a gateway")
        #expect(mtimes() == before, "a test process must never rewrite the user's real instruction files")
    }
}
