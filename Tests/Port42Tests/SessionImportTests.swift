import Testing
import Foundation
@testable import Port42Lib

// Bring running sessions into Port42 (docs/plan-session-import.md), step 1: finding them. Pure over a
// fake process list and a fake home with Claude's and Codex's session logs.
@Suite("Session import: finding running sessions")
struct SessionImportTests {

    struct Home {
        let root: String
        let repo: String
        let now = Date()
        init() throws {
            root = NSTemporaryDirectory() + "p42-import-\(UUID().uuidString)"
            repo = "\(root)/code/port42-native"
            let fm = FileManager.default
            try fm.createDirectory(atPath: "\(repo)/.git", withIntermediateDirectories: true)
            try "ref: refs/heads/nautilus\n".write(toFile: "\(repo)/.git/HEAD", atomically: true, encoding: .utf8)
        }
        func claudeLog(_ id: String, cwd: String, title: String? = nil, first: String = "fix the stall", age: TimeInterval = 60) throws {
            let dir = "\(root)/.claude/projects/-slug"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var lines = [#"{"type":"user","cwd":"\#(cwd)","message":{"role":"user","content":"\#(first)"}}"#]
            if let title { lines.append(#"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"\#(id)"}"#) }
            let path = "\(dir)/\(id).jsonl"
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
        }
        func codexLog(_ id: String, cwd: String, first: String, age: TimeInterval = 60) throws {
            let dir = "\(root)/.codex/sessions/2026/09/26"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let lines = [#"{"type":"session_meta","payload":{"session_id":"\#(id)","cwd":"\#(cwd)"}}"#,
                         ##"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
                         #"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"\#(first)"}]}}"#]
            let path = "\(dir)/rollout-\(id).jsonl"
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
        }
    }

    // A terminal app, a Port42 app, and shells under each.
    func procs(_ h: Home) -> [SessionImport.Proc] {
        [
            .init(pid: 10, ppid: 1, args: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            .init(pid: 11, ppid: 10, args: "login -pf gordon"),
            .init(pid: 12, ppid: 11, args: "-zsh"),
            .init(pid: 13, ppid: 12, args: "claude", cwd: h.repo, tty: "ttys001"),                  // outside: found
            .init(pid: 14, ppid: 12, args: "/Users/g/.local/bin/claude daemon run", cwd: h.repo),   // helper: not a session
            .init(pid: 20, ppid: 1, args: "/Applications/Port42.app/Contents/MacOS/Port42"),
            .init(pid: 21, ppid: 20, args: "/usr/bin/login -flp gordon /bin/bash"),
            .init(pid: 22, ppid: 21, args: "-/bin/zsh"),
            .init(pid: 23, ppid: 22, args: "claude", cwd: h.repo),                                  // Port42's own: skipped
            .init(pid: 30, ppid: 12, args: "node /Users/g/.nvm/bin/codex", cwd: h.root, tty: "ttys002"), // codex: found once
            .init(pid: 31, ppid: 30, args: "/Users/g/.nvm/lib/node_modules/@openai/codex/bin/codex", cwd: h.root),
            .init(pid: 32, ppid: 12, args: "node /Users/g/.nvm/bin/codex exec do-a-thing", cwd: h.root), // non-interactive
        ]
    }

    @Test("finds outside sessions with their project, branch, title and host app; skips Port42's own and helpers")
    func finds() throws {
        let h = try Home()
        defer { try? FileManager.default.removeItem(atPath: h.root) }
        try h.claudeLog("c-1", cwd: h.repo, title: "fix the gateway stall", age: 120)
        try h.claudeLog("p42-own", cwd: h.repo, title: "a Port42 companion's session", age: 10)   // newer, and Port42's
        try h.codexLog("x-1", cwd: h.root, first: "write the release notes")
        let found = SessionImport.find(procs: procs(h), home: h.root, now: h.now)
        #expect(found.count == 2, "\(found.map { "\($0.cli) \($0.pid)" })")
        let c = try #require(found.first { $0.cli == .claude })
        #expect(c.pid == 13 && c.project == "port42-native" && c.branch == "nautilus")
        #expect(!found.contains { $0.pid == 23 }, "a session Port42 started was offered for import")
        #expect(c.app == "Terminal" && c.tty == "ttys001")
        let x = try #require(found.first { $0.cli == .codex })
        #expect(x.pid == 30 && x.sessionId == "x-1" && x.title == "write the release notes", "codex's injected AGENTS.md is not its title")
    }

    @Test("two sessions in one folder each get their own log, newest first; a named --resume gets that one")
    func matching() throws {
        let h = try Home()
        defer { try? FileManager.default.removeItem(atPath: h.root) }
        try h.claudeLog("old", cwd: h.repo, first: "older work", age: 3600)
        try h.claudeLog("new", cwd: h.repo, first: "newer work", age: 30)
        try h.claudeLog("named", cwd: h.repo, first: "named work", age: 10)
        var ps = procs(h).filter { $0.pid < 20 }
        ps.append(.init(pid: 15, ppid: 12, args: "claude --resume old", cwd: h.repo))
        ps.append(.init(pid: 16, ppid: 12, args: "claude", cwd: h.repo))
        let found = SessionImport.find(procs: ps, home: h.root, now: h.now)
        let byPid = Dictionary(uniqueKeysWithValues: found.map { ($0.pid, $0.sessionId) })
        #expect(byPid[15] == "old", "a named session is the one it runs")
        #expect(Set([byPid[13], byPid[16]]) == Set(["named", "new"]), "the others take the newest unclaimed logs: \(byPid)")
    }

    @Test("a log with no running process is not a session to import, and a Claude title falls back to the first request")
    func noProcessNoSession() throws {
        let h = try Home()
        defer { try? FileManager.default.removeItem(atPath: h.root) }
        try h.claudeLog("lonely", cwd: "\(h.root)/elsewhere", first: "a very long first request that goes on and on past the limit of sixty characters")
        #expect(SessionImport.find(procs: procs(h).filter { $0.pid < 20 }, home: h.root, now: h.now).isEmpty)
        try h.claudeLog("c-2", cwd: h.repo, first: "a very long first request that goes on and on past the limit of sixty characters")
        let c = try #require(SessionImport.find(procs: procs(h).filter { $0.pid < 20 }, home: h.root, now: h.now).first)
        #expect(c.title.hasSuffix("…") && c.title.count == 60)
    }
}
