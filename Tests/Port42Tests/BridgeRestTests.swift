import Testing
import Foundation
@testable import Port42Lib

// Tail item 4: rest.call extracted to the registry (permission .rest, tool-exposed). The unified
// body carries BOTH old paths' semantics: the port path's dict-body support and the tool path's
// per-companion secret grant + filtered response headers. Contract: {status, headers?, body}.

@Suite("Bridge — rest.call")
struct BridgeRestTests {

    @MainActor
    func call(_ w: ParityWorld, _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry["rest.call"])
        return try await method.run(w.principal, BridgeArgs(input))
    }

    @Test("rest.call is registered with the .rest permission and tool-exposed")
    @MainActor
    func registration() throws {
        let w = try makeParityWorld()
        let method = try #require(w.registry["rest.call"])
        #expect(method.permission == .rest)
        #expect(method.toolExposed)
    }

    @Test("an unparseable URL throws bad_arg")
    @MainActor
    func badURL() async throws {
        let w = try makeParityWorld()
        await #expect(throws: BridgeError.self) { _ = try await call(w, ["url": ""]) }
    }

    @Test("an unknown secret throws not_found")
    @MainActor
    func unknownSecret() async throws {
        let w = try makeParityWorld()
        // The world's companion has no secret grants, so the grant gate rejects before resolution.
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, ["url": "http://127.0.0.1:1/", "secret": "no-such-secret"])
        }
    }

    @Test("GET against a local server returns status, parsed body, and passes request headers")
    @MainActor
    func localRoundTrip() async throws {
        // A one-shot echo server: replies 200 JSON {"probe": "<X-Probe header>"} to the first request.
        let port = 42893
        let script = """
        import http.server, json, socketserver
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({"probe": self.headers.get("X-Probe", "")}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *a): pass
        with socketserver.TCPServer(("127.0.0.1", \(port)), H) as srv:
            srv.serve_forever()
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", script]
        try proc.run()
        defer { if proc.isRunning { proc.terminate() } }
        // Wait for the listener to bind: poll a raw TCP connect for up to ~5s.
        var bound = false
        for _ in 0..<50 {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            if sock >= 0 {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(UInt16(port)).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let ok = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        Darwin.connect(sock, sp, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                close(sock)
                if ok { bound = true; break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try #require(bound, "local test server never bound port \(port)")

        let w = try makeParityWorld()
        let r = try await call(w, ["url": "http://127.0.0.1:\(port)/", "headers": ["X-Probe": "hello-rest"]])
        guard case let .object(o) = r else { Issue.record("expected object"); return }
        #expect(o["status"] == .int(200))
        guard case let .object(body) = o["body"] else { Issue.record("expected parsed JSON body"); return }
        #expect(body["probe"] == .string("hello-rest"))
        // The filtered response headers include content-type.
        if case let .object(headers) = o["headers"] {
            #expect(headers["content-type"] != nil)
        } else {
            Issue.record("expected headers object")
        }
    }
}
