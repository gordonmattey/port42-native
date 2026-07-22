import Testing
import Foundation
@testable import Port42Lib

// ScreenRecorder status + teardown seam (screen.record Step 5). Headless-safe: exercises the
// empty-recorder paths only (a populated Active holds a real SCStream, which needs a display + TCC
// and is covered by the live spike mode E). The finalize-on-owner-death guarantee is live-verified.
@Suite("ScreenRecorder teardown")
@MainActor
struct ScreenRecorderTeardownTests {

    @Test("a fresh recorder is not recording")
    func idle() {
        let r = ScreenRecorder()
        #expect(r.isRecording == false)
    }

    @Test("status(nil) on an idle recorder reports not recording")
    func statusOverallIdle() {
        let s = ScreenRecorder().status(recordingId: nil)
        #expect(s["recording"] as? Bool == false)
        #expect(s["elapsed"] as? Double == 0.0)
        #expect(s["count"] as? Int == 0)
    }

    @Test("status(id) for an unknown recording reports not recording")
    func statusUnknownId() {
        let s = ScreenRecorder().status(recordingId: "nope")
        #expect(s["recording"] as? Bool == false)
        #expect(s["elapsed"] as? Double == 0.0)
    }

    @Test("releaseIfOwned on an idle recorder is a safe no-op")
    func releaseNoOp() {
        let r = ScreenRecorder()
        r.releaseIfOwned(byPortId: "any")
        r.releaseIfOwned(byPortId: "any")   // idempotent
        #expect(r.isRecording == false)
    }

    @Test("cleanup on an idle recorder is a safe no-op")
    func cleanupNoOp() {
        let r = ScreenRecorder()
        r.cleanup()
        #expect(r.isRecording == false)
    }
}
