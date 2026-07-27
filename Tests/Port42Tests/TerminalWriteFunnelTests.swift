import Testing
import Foundation
@testable import Port42Lib

/// R2b — ONE surface writer (docs/plan-port42-protocol-local-bus.md, verification finding 7).
///
/// The rule this pins: **bump at the SURFACE, not at the API.** Three separate sweeps for "every
/// way into a terminal" each found a path the previous sweep had missed, so a guarantee that
/// depends on someone having enumerated the callers is not a guarantee — it is a to-do list that
/// rots silently. Instead every programmatic write funnels through `GhosttyInputView.write(_:mode:)`,
/// which is the only thing permitted to call Ghostty's text entry points.
///
/// That makes the property GREPPABLE, which is what this suite does. A new write path physically
/// cannot reach the pty without either going through the funnel (and counting) or failing this test.
@Suite("Terminal write funnel (R2b)")
struct TerminalWriteFunnelTests {

    /// Source of a file under Sources/, read from disk. Same shape as the other source-scan gates.
    func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Port42Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Port42Lib/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Non-comment lines that call one of Ghostty's raw text-entry functions.
    func rawWriteCalls(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { return false }
                return t.contains("ghostty_surface_text(") || t.contains("ghostty_surface_text_input(")
            }
    }

    @Test("programmatic text enters a pty in exactly ONE place")
    func oneWriter() throws {
        let view = try source("Views/GhosttyTerminalView.swift")
        let calls = rawWriteCalls(in: view)

        // Both entry points, both inside `write(_:mode:)` — one call each, nowhere else in the file.
        #expect(calls.count == 2,
                "expected exactly 2 raw calls (one per mode) inside write(_:mode:), found \(calls.count):\n\(calls.joined(separator: "\n"))")

        // …and they are in the funnel, not scattered. Everything from `func write(` to the end of
        // that method must contain them.
        let funnelStart = try #require(view.range(of: "func write(_ text: String, mode: WriteMode)"))
        let after = String(view[funnelStart.lowerBound...])
        let inFunnel = rawWriteCalls(in: String(after.prefix(600)))
        #expect(inFunnel.count == 2, "both raw calls must live inside write(_:mode:)")
    }

    @Test("NO file in the whole source tree reaches the pty directly, except the funnel")
    func noOtherCallersAnywhere() throws {
        // Scans EVERY .swift under Sources/. An earlier version of this test checked four files by
        // name, which was the very failure the funnel exists to prevent: a hand-maintained list
        // that a new file silently escapes. The point is not "these files are clean", it is
        // "exactly one file in the repo may do this".
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")

        var offenders: [String: [String]] = [:]
        let walker = try #require(FileManager.default.enumerator(at: root,
                                                                 includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let calls = rawWriteCalls(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            if !calls.isEmpty { offenders[url.lastPathComponent] = calls }
        }

        // The funnel itself, plus the DEBUG-only resize harness, which is not a user-reachable path.
        let allowed: Set<String> = ["GhosttyTerminalView.swift", "GhosttyResizeSpike.swift"]
        let unexpected = Set(offenders.keys).subtracting(allowed)
        #expect(unexpected.isEmpty,
                "these files write to a pty outside the funnel: \(unexpected.sorted().joined(separator: ", "))")

        // And the funnel file must actually be found — a scan that silently matched nothing would
        // pass this test while proving nothing at all.
        #expect(offenders["GhosttyTerminalView.swift"]?.count == 2,
                "the scan did not find the funnel's own two calls; the walk or the matcher is broken")
    }

    @Test("the funnel counts — a write that does not bump is not a write")
    func funnelCounts() throws {
        let view = try source("Views/GhosttyTerminalView.swift")
        // The hook the host wires to `AppState.surfaceWrote`. If someone deletes this line the
        // funnel still compiles and still writes, and every token silently stops moving — which is
        // the failure mode worth a test, because nothing else would surface it.
        #expect(view.contains("onSurfaceWrite?()"),
                "write(_:mode:) must fire onSurfaceWrite, or the token stops tracking the pty")
    }

    @Test("a terminal surface is built and wired in exactly ONE place (I2 · C0)")
    func oneTerminalSurfaceFactory() throws {
        // SUPERSEDES `bothHostsWireIt`, which asserted that both build paths wired the token hook.
        // That was the right property while there were two paths, but "remember to wire it in both"
        // is the discipline this seam has failed at four times. C0 collapsed them into
        // `AppState.buildTerminalSurface`, so the property to hold is now stronger and structural:
        // there is ONE site, therefore there is nothing to keep in sync.
        //
        // It was not a hypothetical. A THIRD caller (`PortWindowManager.restart`) did step one of
        // five and skipped the rest, leaving a controller bound to no surface. Nothing caught it
        // because the old test asked "do these two files each contain the wiring", which stays true
        // no matter how many other places get it wrong.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root,
                                                                 includingPropertiesForKeys: nil))
        var builders: [String: Int] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let file = url.lastPathComponent
            // `makeDetached`'s own definition, and the DEBUG resize harness, which deliberately
            // drives the production surface without app wiring. Same allow-list as `oneWriter`.
            guard file != "GhosttyTerminalView.swift", file != "GhosttyResizeSpike.swift" else { continue }
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let n = src.components(separatedBy: "GhosttyTerminalView.makeDetached(").count - 1
            if n > 0 { builders[file] = n }
        }
        #expect(builders == ["AppState.swift": 1], """
            A terminal surface must be built in exactly one place, \
            AppState.buildTerminalSurface. Found: \(builders.sorted(by: { $0.key < $1.key })).
            """)

        // And that one place must wire BOTH hooks, or the single site is single and wrong.
        let factory = try source("Services/AppState.swift")
        #expect(factory.contains("onHumanInput = "), "the factory must wire presence")
        #expect(factory.contains("onSurfaceWrite = "), "the factory must wire the activity token")
    }

    @Test("a browser port watches its URL, not just its address bar (I2 · C3)")
    func browserNavigationIsObserved() throws {
        let pwm = try source("Views/PortWindowManager.swift")

        // The observer must exist and be INSTALLED, not merely defined.
        #expect(pwm.contains("PortBrowserURLObserver("),
                "a browser port must install a URL observer, or only the address bar counts")
        #expect(pwm.contains("browserURLObservers.removeValue"),
                "the observer must be freed with the webview, or it outlives its port")

        // KVO on `url`, NOT didCommit. Spike B verified live that `history.pushState` changes the
        // URL with no document load, so no commit fires and every SPA route change is invisible.
        // A single-page app is the common case, so committing-only counts the minority.
        let observer = try #require(pwm.range(of: "final class PortBrowserURLObserver"))
        let body = String(pwm[observer.lowerBound...].prefix(1200))
        #expect(body.contains("observe(\\.url"),
                "must observe `url`; didCommit misses pushState (Spike B)")

        // C6 measured that KVO alone is not enough either: a RELOAD replaces the document with the
        // URL unchanged, so `url` never fires and the reload counted for nothing. Spike B's
        // "necessary but not sufficient" means use BOTH, not one instead of the other.
        #expect(pwm.contains("didCommit navigation"),
                "a reload must count: it commits a document without changing the URL")
        #expect(pwm.contains("onCommitted = "),
                "the commit hook must be WIRED, not merely declared")
    }

    @Test("the non-terminal ways in are counted too (finding 7)")
    func webAndBrowserPathsCount() throws {
        // A file drop onto a WEB port: an external write into the runtime, never through the
        // dispatcher.
        #expect(try source("Services/PortBridge.swift").contains("surfaceWrote(port:"),
                "a web-port file drop must move the token")
        // A URL typed into a browser tile's address bar: replaces the entire page.
        #expect(try source("Views/ShellDesktop.swift").contains("surfaceWrote(port:"),
                "the browser address bar must move the token")
    }
}
