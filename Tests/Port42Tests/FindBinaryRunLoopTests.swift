import Testing
import Foundation
@testable import Port42Lib

/// `findBinary` is called while SwiftUI draws (the setup screen's agent scan). Its `which` fallback used
/// `waitUntilExit()`, which runs the main run loop while it waits; a turn of the run loop mid-draw let
/// SwiftUI begin a second transaction inside the first, and AttributeGraph aborted the app (a new user's
/// first run on 1.0.3, 2026-09-29). It must wait without running the run loop.
@Suite("Finding a CLI never runs the main run loop")
@MainActor
struct FindBinaryRunLoopTests {

    @Test("the which fallback does not run work queued on the main run loop while it waits")
    func noRunLoopTurn() {
        var ranDuring = false
        var inside = true
        RunLoop.main.perform { if inside { ranDuring = true } }
        // A name in no common location, so the `which` fallback runs.
        _ = ClaudeCodeSetup.findBinary("port42-no-such-cli-\(UUID().uuidString.prefix(6))")
        inside = false
        #expect(!ranDuring, "findBinary turned the main run loop, which is what aborted SwiftUI mid-draw")
    }

    @Test("it still finds a real command through which")
    func stillFinds() {
        #expect(ClaudeCodeSetup.findBinary("ls") != nil)
    }
}
