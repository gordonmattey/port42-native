import Testing
import Foundation
@testable import Port42Lib

// The door stopped reading on Dev4 (2026-09-26): after 12:16:10 every call timed out, the socket was
// open, 11,428 bytes sat unread on the app's side and nothing was logged. These run the REAL gateway
// binary and a REAL door, with no app, and push traffic at it until a small call no longer answers.
@Suite("Gateway door under load, with the real gateway", .serialized)
@MainActor
struct GatewayStallTests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The gateway, built once per run from this checkout.
    static let binary: URL? = {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("p42-stall-gateway-\(getpid())")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["go", "build", "-o", out.path, "."]
        p.currentDirectoryURL = root.appendingPathComponent("gateway")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/go/bin:/opt/homebrew/bin"
        p.environment = env
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }()

    final class Gateway {
        let process = Process()
        let stdin = Pipe()
        let port: Int
        init(binary: URL, port: Int, credential: String) throws {
            self.port = port
            process.executableURL = binary
            process.arguments = ["-addr", "127.0.0.1:\(port)", "-watch-parent"]
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write((credential + "\n").data(using: .utf8)!)
        }
        deinit { process.terminate() }
    }

    static func freePort() -> Int { Int.random(in: 47000..<48900) }

    /// An HTTP /call as any client makes it. Returns the body, or nil when nothing came back in time.
    nonisolated static func call(_ port: Int, _ method: String, args: [String: Any] = [:], timeout: TimeInterval = 8) async -> [String: Any]? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/call")!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer p42_test", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["method": method, "args": args])
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    final class Rig {
        let gateway: Gateway
        let door: GatewayDoor
        var port: Int { gateway.port }
        init(gateway: Gateway, door: GatewayDoor) { self.gateway = gateway; self.door = door }
        @MainActor func close() { door.disconnect() }
    }

    /// A gateway, and a door connected to it as host whose handler answers `echo` with the size of
    /// what it got and `blob` with `n` bytes.
    func rig() async throws -> Rig {
        let bin = try #require(Self.binary, "could not build the gateway (is go installed?)")
        let port = Self.freePort()
        let gw = try Gateway(binary: bin, port: port, credential: "host-secret")
        for _ in 0..<100 {
            if (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let door = GatewayDoor()
        door.hostCredentialOverride = "host-secret"
        door.onCallReceived = { _, _, method, args, _, _ in
            switch method {
            case "blob": return ["data": String(repeating: "x", count: (args["n"] as? NSNumber)?.intValue ?? 0)]
            case "nan": return ["speed": Double.nan, "far": Double.infinity, "ok": 1]
            case "slow":
                try? await Task.sleep(nanoseconds: UInt64(((args["s"] as? NSNumber)?.doubleValue ?? 1) * 1e9))
                return ["slept": true]
            default: return ["got": (try? JSONSerialization.data(withJSONObject: args).count) ?? -1]
            }
        }
        door.configure(gatewayURL: "ws://127.0.0.1:\(port)", senderId: "HOST-1", senderName: "host")
        door.connect()
        for _ in 0..<100 where !door.isConnected { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(door.isConnected, "the door never opened")
        return Rig(gateway: gw, door: door)
    }

    func stillAnswers(_ r: Rig, after what: String) async {
        let ok = await Self.call(r.port, "echo", args: ["ping": 1], timeout: 5)
        #expect(ok?["content"] != nil, "a small call no longer answers after \(what): \(String(describing: ok))")
    }

    @Test("a burst of 300 concurrent small calls: every one answers (the host is not rate limited), and so does the next")
    func burst() async throws {
        let r = try await rig()
        let port = r.port
        let answered = await withTaskGroup(of: Bool.self) { g in
            for i in 0..<300 { g.addTask { await Self.call(port, "echo", args: ["i": i])?["content"] != nil } }
            return await g.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(answered == 300)
        await stillAnswers(r, after: "a burst")
        r.close()
    }

    @Test("a call whose args are 1.5 MB (under the gateway's 2 MB, over URLSession's default 1 MiB)")
    func bigCall() async throws {
        let r = try await rig()
        let big = await Self.call(r.port, "echo", args: ["html": String(repeating: "y", count: 1_500_000)], timeout: 10)
        #expect((big?["content"] as? String)?.contains("\"got\"") == true, "the door dropped a 1.5 MB call: \(String(describing: big).prefix(160))")
        await stillAnswers(r, after: "a 1.5 MB call")
        r.close()
    }

    @Test("a result of 1.5 MB")
    func bigResult() async throws {
        let r = try await rig()
        let big = await Self.call(r.port, "blob", args: ["n": 1_500_000], timeout: 10)
        #expect(((big?["content"] as? String)?.count ?? 0) > 1_500_000)
        await stillAnswers(r, after: "a 1.5 MB result")
        r.close()
    }

    @Test("a result of 3 MB (over one frame) is refused at once with too_large, and the door stays open")
    func hugeResult() async throws {
        let r = try await rig()
        let t0 = Date()
        let big = await Self.call(r.port, "blob", args: ["n": 3_000_000], timeout: 10)
        #expect((big?["content"] as? String)?.contains("too_large") == true, "\(String(describing: big).prefix(160))")
        #expect(Date().timeIntervalSince(t0) < 5, "the caller waited for a timeout instead of an answer")
        await stillAnswers(r, after: "a 3 MB result")
        r.close()
    }

    @Test("sustained mixed load under the rate limit: small, 200 KB results, slow calls, callers that give up", .enabled(if: ProcessInfo.processInfo.environment["PORT42_STRESS"] == "1"))
    func sustained() async throws {
        let r = try await rig()
        let port = r.port
        let started = Date()
        var answered = 0, asked = 0
        while Date().timeIntervalSince(started) < 20 {
            let batch = await withTaskGroup(of: Bool.self) { g in
                for i in 0..<20 {
                    g.addTask {
                        switch i % 5 {
                        case 0: return await Self.call(port, "blob", args: ["n": 200_000])?["content"] != nil
                        case 1: return await Self.call(port, "slow", args: ["s": 3], timeout: 1) == nil   // gives up
                        case 2: return await Self.call(port, "echo", args: ["html": String(repeating: "z", count: 300_000)])?["content"] != nil
                        default: return await Self.call(port, "echo", args: ["i": i])?["content"] != nil
                        }
                    }
                }
                return await g.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
            answered += batch; asked += 20
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("sustained: \(answered) of \(asked) as expected")
        await stillAnswers(r, after: "20 s of mixed load")
        r.close()
    }

    @Test("stress: 60 s, 40 at a time, 400 KB both ways, under the rate limit per second", .enabled(if: ProcessInfo.processInfo.environment["PORT42_STRESS"] == "1"))
    func stress() async throws {
        let r = try await rig()
        let port = r.port
        let started = Date()
        var failed = 0, asked = 0
        while Date().timeIntervalSince(started) < 60 {
            let batch = await withTaskGroup(of: Bool.self) { g in
                for i in 0..<25 {
                    g.addTask {
                        if i % 2 == 0 { return await Self.call(port, "blob", args: ["n": 400_000], timeout: 15)?["content"] != nil }
                        return await Self.call(port, "echo", args: ["html": String(repeating: "q", count: 400_000)], timeout: 15)?["content"] != nil
                    }
                }
                return await g.reduce(0) { $0 + ($1 ? 0 : 1) }
            }
            failed += batch; asked += 25
            if batch > 0 { print("stress: \(batch) of 25 failed at \(Int(Date().timeIntervalSince(started)))s") }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("stress: \(failed) of \(asked) failed")
        #expect(failed == 0)
        await stillAnswers(r, after: "60 s of stress")
        r.close()
    }

    @Test("a result holding NaN and infinity answers with nulls, and the door keeps reading (Dev4, 12:16:10)")
    func nanResult() async throws {
        let r = try await rig()
        let v = await Self.call(r.port, "nan", timeout: 5)
        let content = try #require(v?["content"] as? String, "no answer: \(String(describing: v))")
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        #expect(obj["speed"] is NSNull && obj["far"] is NSNull && (obj["ok"] as? Int) == 1)
        await stillAnswers(r, after: "a NaN result")
        r.close()
    }
}
