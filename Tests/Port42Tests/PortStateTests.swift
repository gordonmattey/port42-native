import Testing
import Foundation
import GhosttyKit
@testable import Port42Lib

/// A terminal's own reports become its port's state (docs/plan-port-state-v1.md, Phase A). Ghostty sent
/// them all along; Port42's handler dropped every one until 2026-09-29.
@Suite("A terminal's reports become its port's state")
struct PortStateTests {

    func action(_ tag: ghostty_action_tag_e, _ fill: (inout ghostty_action_s) -> Void = { _ in }) -> ghostty_action_s {
        var a = ghostty_action_s()
        a.tag = tag
        fill(&a)
        return a
    }

    @Test("each Ghostty action Port42 uses decodes to its event; the rest are left alone")
    func decodes() {
        "probe-title".withCString { t in
            #expect(TerminalEvent.decode(action(GHOSTTY_ACTION_SET_TITLE) { $0.action.set_title.title = t }) == .title("probe-title"))
        }
        "file://mac.local/tmp/a%20b".withCString { p in
            #expect(TerminalEvent.decode(action(GHOSTTY_ACTION_PWD) { $0.action.pwd.pwd = p }) == .pwd("file://mac.local/tmp/a%20b"))
        }
        let failed = action(GHOSTTY_ACTION_COMMAND_FINISHED) {
            $0.action.command_finished.exit_code = 1
            $0.action.command_finished.duration = 1_500_000_000
        }
        #expect(TerminalEvent.decode(failed) == .commandFinished(exit: 1, seconds: 1.5))
        let unknownExit = action(GHOSTTY_ACTION_COMMAND_FINISHED) { $0.action.command_finished.exit_code = -1 }
        #expect(TerminalEvent.decode(unknownExit) == .commandFinished(exit: nil, seconds: 0))
        let forty = action(GHOSTTY_ACTION_PROGRESS_REPORT) {
            $0.action.progress_report.state = GHOSTTY_PROGRESS_STATE_SET
            $0.action.progress_report.progress = 40
        }
        #expect(TerminalEvent.decode(forty) == .progress(.init(percent: 40, failed: false, paused: false)))
        let gone = action(GHOSTTY_ACTION_PROGRESS_REPORT) { $0.action.progress_report.state = GHOSTTY_PROGRESS_STATE_REMOVE }
        #expect(TerminalEvent.decode(gone) == .progress(nil))
        #expect(TerminalEvent.decode(action(GHOSTTY_ACTION_RING_BELL)) == .bell)
        #expect(TerminalEvent.decode(action(GHOSTTY_ACTION_QUIT)) == nil)
    }

    @Test("facts keep the newest of each report; a working directory is read from its file URL")
    func facts() {
        var f = TerminalFacts()
        let t0 = Date(timeIntervalSince1970: 1000)
        f.apply(.pwd("file://mac.local/Users/gordon/My%20Project"), at: t0)
        f.apply(.title("✳ fixing the rail"), at: t0)
        f.apply(.commandFinished(exit: 1, seconds: 2), at: t0)
        f.apply(.progress(.init(percent: 60, failed: false, paused: false)), at: t0)
        f.apply(.bell, at: t0)
        #expect(f.cwd == "/Users/gordon/My Project")
        #expect(f.title == "✳ fixing the rail")
        #expect(f.lastCommand == .init(exit: 1, seconds: 2, at: t0))
        #expect(f.progress?.percent == 60)
        #expect(f.bellAt == t0)
        f.apply(.progress(nil), at: t0)
        f.apply(.commandFinished(exit: 0, seconds: 0.1), at: t0)
        #expect(f.progress == nil && f.lastCommand?.exit == 0)
        #expect(TerminalFacts.path("/plain/path") == "/plain/path")
    }

    @Test("the store keeps facts per port and forgets a closed one")
    @MainActor
    func store() {
        let s = PortStateStore()
        s.apply(.pwd("/tmp"), port: "a")
        s.apply(.bell, port: "b")
        #expect(s.terminals["a"]?.cwd == "/tmp" && s.terminals["b"]?.bellAt != nil)
        s.forget(port: "a")
        #expect(s.terminals["a"] == nil && s.terminals["b"] != nil)
    }

    @Test("Port42's zsh reports each command's exit and the directory, as Ghostty's integration would")
    func shellReports() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shellreports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("reports.zsh")
        try TerminalSessionBootstrap.shellReports.write(to: file, atomically: true, encoding: .utf8)
        // What an interactive zsh does around a failing command: preexec, the command, precmd.
        let steps = "cd \(dir.path); source reports.zsh; __port42_precmd; __port42_preexec; false; __port42_precmd"
        func run(onTerminal: Bool) throws -> String {
            let p = Process()
            // `script` gives the shell a terminal, as Ghostty does; without it the output is a pipe.
            p.executableURL = URL(fileURLWithPath: onTerminal ? "/usr/bin/script" : "/bin/zsh")
            p.arguments = onTerminal ? ["-q", "/dev/null", "/bin/zsh", "-f", "-c", steps] : ["-f", "-c", steps]
            let out = Pipe()
            p.standardOutput = out
            p.standardInput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(!(try run(onTerminal: false)).contains("\u{1B}]"), "escape codes went into piped output")
        let text = try run(onTerminal: true)
        #expect(text.contains("\u{1B}]7;file://"), "no working directory report")
        #expect(text.contains("\u{1B}]133;C\u{07}"), "no command-start report")
        #expect(text.contains("\u{1B}]133;D;1\u{07}"), "the failing command's exit was not reported")
        // The first prompt, before any command ran, reports no command end.
        #expect(text.components(separatedBy: "\u{1B}]133;D").count == 2, "a command end was reported with no command")
    }
}
