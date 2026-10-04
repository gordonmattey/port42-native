import Testing
import Foundation

/// The build gate runs the timing pass after the full suite, so timing tests that skip themselves in
/// the full suite still gate every build (#244). The gate runs against a stand-in `swift` that logs
/// each call, never the real suite.
@Suite("Build test gate")
struct TestGateTests {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Runs scripts/test-gate.sh with a stand-in `swift` that fails the pass named by `failing`
    /// ("suite" or "timing"). Returns the exit status, the output and the calls the stand-in logged.
    private func gate(failing: String? = nil) throws -> (Int32, String, [String]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("test-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls")
        let stub = dir.appendingPathComponent("swift")
        try """
        #!/bin/bash
        pass=suite; [ "${PORT42_TIMING_TESTS:-}" = "1" ] && pass=timing
        echo "$pass PORT42_TIMING_TESTS=${PORT42_TIMING_TESTS:-} $*" >> "\(log.path)"
        if [ "$pass" = "\(failing ?? "")" ]; then echo "✘ Test \\"stand-in\\" failed"; exit 1; fi
        echo "✔ Test run with 1 test in 1 suite passed"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.root.appendingPathComponent("scripts/test-gate.sh").path]
        p.environment = ["PATH": "\(dir.path):/usr/bin:/bin", "HOME": dir.path, "TMPDIR": dir.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        return (p.terminationStatus, output, calls)
    }

    @Test("the full suite runs, then the timing pass with PORT42_TIMING_TESTS=1")
    func bothPasses() throws {
        let (status, output, calls) = try gate()
        #expect(status == 0, "\(output)")
        #expect(calls == [
            "suite PORT42_TIMING_TESTS= test",
            "timing PORT42_TIMING_TESTS=1 test --filter OffscreenTimerTests|HiddenTimerTests|MessageDeliveryTests",
        ])
    }

    @Test("a failing timing test aborts the build")
    func timingFailureAborts() throws {
        let (status, output, calls) = try gate(failing: "timing")
        #expect(status == 1)
        #expect(output.contains("TESTS FAILED (timing)"))
        #expect(calls.count == 2)
    }

    @Test("a failing suite aborts before the timing pass")
    func suiteFailureAborts() throws {
        let (status, output, calls) = try gate(failing: "suite")
        #expect(status == 1)
        #expect(output.contains("TESTS FAILED (suite)"))
        #expect(calls.count == 1)
    }
}
