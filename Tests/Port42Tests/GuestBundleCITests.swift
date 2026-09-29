import Testing
import Foundation

/// CI rebuilds the guest bundle from the lockfile and fails on any byte of difference in the bundle or
/// the page's SRI hash (BLD-11). The bundle is a committed artifact tele.port42.ai serves, and nothing
/// checked it against its source except a local test run against whatever node_modules was installed.
@Suite("Guest bundle CI")
struct GuestBundleCITests {
    @Test("a workflow runs npm ci, rebuilds, and diffs the bundle and invite.html")
    func rebuildCheck() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/guest.yml")
        let wf = try String(contentsOf: url, encoding: .utf8)
        #expect(wf.contains("npm ci"), "the bundle must build from the lockfile")
        #expect(wf.contains("npm run build"))
        #expect(wf.contains("git diff --exit-code -- dist/port42-guest.js invite.html"))
        #expect(wf.contains("guest/**"), "the check must run when the guest changes")
    }
}
