import Testing
import Foundation
import Darwin
@testable import Port42Lib

@Suite("Terminal Hooks Service")
struct TerminalHooksServiceTests {

    /// Connect to a Unix domain socket and write `payload`, then close (one event per conn,
    /// matching how the shim's notifier behaves).
    private func sendToSocket(_ path: String, _ payload: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            let n = strlen(cstr)
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(n) + 1) { dst in
                    memcpy(dst, cstr, n); dst[Int(n)] = 0
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        #expect(rc == 0)
        _ = payload.withCString { write(fd, $0, strlen($0)) }
    }

    @Test("turnComplete normalized event arrives over the socket")
    func turnCompleteRoundTrip() async throws {
        let sock = "/tmp/p42h-test-\(UInt32.random(in: 0..<1_000_000)).sock"
        let service = TerminalHooksService(socketPath: sock)
        let stream = await service.events()

        // Give the listener a moment to bind/listen before connecting.
        try await Task.sleep(nanoseconds: 100_000_000)
        try sendToSocket(sock, #"{"event":"turnComplete","text":"banana","exitCode":0}"#)

        var received: TerminalHookEvent?
        let collector = Task {
            for await event in stream { received = event; break }
        }
        // Bound the wait so a failure doesn't hang the suite.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        collector.cancel()
        await service.stop()

        #expect(received == .turnComplete(text: "banana", exitCode: 0))
    }

    @Test("toolStarting event decodes tool name")
    func toolStartingDecodes() async throws {
        let sock = "/tmp/p42h-test-\(UInt32.random(in: 0..<1_000_000)).sock"
        let service = TerminalHooksService(socketPath: sock)
        let stream = await service.events()
        try await Task.sleep(nanoseconds: 100_000_000)
        try sendToSocket(sock, #"{"event":"toolStarting","tool":"Bash","input":"ls"}"#)

        var received: TerminalHookEvent?
        let collector = Task { for await e in stream { received = e; break } }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        collector.cancel()
        await service.stop()

        #expect(received == .toolStarting(tool: "Bash", input: "ls"))
    }

    @Test("session bootstrap assembles required env vars")
    func bootstrapEnv() {
        let session = TerminalSessionBootstrap.make(
            sessionId: "ABCDEF12-3456-7890-ABCD-EF1234567890",
            spaceId: "space-1", spaceName: "demo", shimPath: nil,
            claudePath: "/usr/bin/true", oauthToken: ""   // skip the slow which/Keychain lookups
        )
        #expect(session.env["PORT42_HOOKS_SOCKET"] == session.socketPath)
        #expect(session.env["PORT42_SPACE_ID"] == "space-1")
        #expect(session.env["PORT42_SPACE_NAME"] == "demo")
        #expect(session.env["PATH"]?.isEmpty == false)
        #expect(session.socketPath.count < 104)   // sockaddr_un.sun_path limit
    }

    @Test("customEnv merges into the session but cannot clobber hooks vars")
    func customEnvMerge() {
        let session = TerminalSessionBootstrap.make(
            sessionId: "CUSTENV0-1111-2222-3333-444444444444",
            spaceId: "space-1", spaceName: "demo",
            customEnv: [
                "FOO": "bar",                          // benign custom var → passes through
                "PORT42_HOOKS_SOCKET": "/evil/sock",   // attempt to hijack the socket
                "PATH": "/evil/bin",                   // attempt to hijack PATH
            ],
            shimPath: nil, claudePath: "/usr/bin/true", oauthToken: "")
        #expect(session.env["FOO"] == "bar")                                  // custom var survives
        #expect(session.env["PORT42_HOOKS_SOCKET"] == session.socketPath)     // hooks socket wins
        #expect(session.env["PATH"] != "/evil/bin")                          // real PATH wins
        #expect(session.env["PATH"]?.isEmpty == false)
    }

    @Test("zsh integration injects a winning claude() function when a shim is present")
    func zshIntegration() throws {
        let session = TerminalSessionBootstrap.make(
            sessionId: "ZSHTEST0-1111-2222-3333-444444444444",
            spaceId: "s", spaceName: "n", shimPath: "/tmp/fake-port42-shim",
            claudePath: "/usr/bin/true", oauthToken: "")
        defer { TerminalSessionBootstrap.cleanup(tempDir: session.tempDir) }
        #expect(session.env["PORT42_CLAUDE_SHIM"] == "/tmp/fake-port42-shim")
        #expect(session.env["ZDOTDIR"] == session.tempDir)
        let zshrc = try String(contentsOfFile: "\(session.tempDir)/.zshrc", encoding: .utf8)
        #expect(zshrc.contains("claude() {"))
        #expect(zshrc.contains("$PORT42_CLAUDE_SHIM"))
        #expect(zshrc.contains("source"))   // sources the user's real .zshrc first
        TerminalSessionBootstrap.cleanup(tempDir: session.tempDir)
    }
}
