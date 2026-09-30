import Testing
import Foundation
@testable import Port42Lib

/// The dev-lock holder gets a client of their own on the instance, and loses it on release (#222).
@Suite("Dev lock enrolment", .serialized)
@MainActor
struct DevLockEnrolmentTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("dev instances take lock requests; the daily driver never does")
    func appliesToDevOnly() {
        #expect(DevLockEnrolment.applies(to: "Port42Dev8"))
        #expect(DevLockEnrolment.applies(to: "Port42Dev"))
        #expect(!DevLockEnrolment.applies(to: "Port42"))
    }

    @Test("a lock request enrols the holder with a token file; a release request revokes it; relocking restores it")
    func enrolReleaseRevoke() throws {
        let db = try DatabaseService(inMemory: true)
        let registry = ClientRegistry(db: db, instance: "Port42Dev8Test\(UUID().uuidString.prefix(6))")
        let e = DevLockEnrolment(registry: registry, restore: { try? db.restoreClient(id: $0) })
        let fm = FileManager.default
        try fm.createDirectory(at: e.requestDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: e.requestDirectory.deletingLastPathComponent()) }

        fm.createFile(atPath: e.requestDirectory.appendingPathComponent("Cosmic Hare").path, contents: nil)
        #expect(e.process() == ["enrolled cosmic-hare"])
        #expect(registry.client(id: "cosmic-hare")?.isActive == true)
        let token = registry.tokenPath(id: "cosmic-hare")
        #expect(fm.fileExists(atPath: token.path), "no token file for the holder")
        #expect(try fm.contentsOfDirectory(atPath: e.requestDirectory.path).isEmpty, "the request was not consumed")

        fm.createFile(atPath: e.requestDirectory.appendingPathComponent("Cosmic Hare.revoke").path, contents: nil)
        #expect(e.process() == ["revoked cosmic-hare"])
        #expect(registry.client(id: "cosmic-hare")?.isActive == false, "release did not revoke the client")
        #expect(!fm.fileExists(atPath: token.path), "a revoked client kept its token file")

        fm.createFile(atPath: e.requestDirectory.appendingPathComponent("Cosmic Hare").path, contents: nil)
        e.process()
        #expect(registry.client(id: "cosmic-hare")?.isActive == true, "taking the lock again did not bring the client back")
    }

    /// Runs scripts/dev-lock.sh with a throwaway HOME and returns its status and output.
    private func devLock(_ args: [String], home: URL, buildDir: String? = nil, port: Int? = nil) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/dev-lock.sh").path] + args
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        if let buildDir { env["PORT42_DEVLOCK_BUILD_DIR"] = buildDir }
        env["PORT42_DEVLOCK_PORT"] = String(port ?? Self.freePort())
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// A port nothing listens on, so a real dev instance on this machine cannot affect the test.
    static func freePort() -> Int { Int.random(in: 42_000...42_999) }

    @Test("the script: taking a lock asks for the holder's client and names its token path; releasing asks for a revoke")
    func scriptRequests() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("devlock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let enrol = home.appendingPathComponent(".port42/port42dev2/enrol")

        let (took, out) = try devLock(["dev2", "Keel Test", "#222"], home: home, buildDir: "/nonexistent-own-build")
        #expect(took == 0, "\(out)")
        #expect(out.contains(".port42/port42dev2/tokens/keel-test"), "no token path in: \(out)")
        let request = enrol.appendingPathComponent("Keel Test").path
        #expect(FileManager.default.fileExists(atPath: request))
        let mode = (try FileManager.default.attributesOfItem(atPath: request)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600, "the request is readable by others: \(String(describing: mode))")

        let (released, _) = try devLock(["dev2", "--release"], home: home)
        #expect(released == 0)
        #expect(FileManager.default.fileExists(atPath: enrol.appendingPathComponent("Keel Test.revoke").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".port42/dev-locks/dev2").path))
    }

    /// Listens on 127.0.0.1:port from this test process and returns the socket to close.
    private func listen(on port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && Darwin.listen(fd, 1) == 0, "could not listen on \(port)")
        return fd
    }

    @Test("the script refuses a lock while the gateway port is held from another build folder, and names it")
    func strayApp() throws {
        // NO .app BUNDLE, EVER: a fake one in a temporary folder is registered by LaunchServices and
        // macOS then offers to open it ("the file is corrupted"; seen live 2026-09-30). The stand-in
        // for the other build's app is this test process itself, listening on the port.
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("devlock-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let port = Self.freePort()
        let fd = try listen(on: port)
        defer { close(fd) }
        let runner = try #require(Bundle.main.executablePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })

        let (refused, out) = try devLock(["dev2", "keel", "#222"], home: home, buildDir: "/nonexistent-own-build", port: port)
        #expect(refused == 1, "a lock was taken while another build held the gateway port: \(out)")
        #expect(out.contains("pid") && out.contains("\(port)"), "the refusal does not name what holds the port: \(out)")
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".port42/dev-locks/dev2").path))

        let (took, out2) = try devLock(["dev2", "keel", "#222"], home: home, buildDir: runner, port: port)
        #expect(took == 0, "the app from this checkout's own build blocked its lock: \(out2)")
    }
}
