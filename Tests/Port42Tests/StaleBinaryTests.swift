import Testing
import Foundation

/// No gateway binary is committed (BLD-05). Two pre-credential builds sat in the repo, easy to launch
/// by mistake and inside relay.Dockerfile's build context. build.sh builds the gateway fresh.
@Suite("Stale binaries")
struct StaleBinaryTests {
    @Test("no gateway binary is tracked")
    func noGatewayBinaryTracked() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-files", "gateway/port42-gateway", "gateway/gateway", "Resources/gateway"]
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        git.waitUntilExit()
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "tracked gateway binaries: \(out)")
    }
}
