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

@Suite("Session import: grouping and bringing in")
@MainActor
struct SessionImportFlowTests {

    func cand(_ id: String, _ cli: SessionImport.CLI, project: String, branch: String?, age: TimeInterval) -> SessionImport.Candidate {
        .init(cli: cli, pid: Int32.random(in: 100...9999), cwd: "/tmp/\(project)", project: project, branch: branch,
              sessionId: id, title: "t \(id)", lastActive: Date().addingTimeInterval(-age), app: "Terminal", tty: nil)
    }

    @Test("grouped by project, newest first; the last day ticked; moving, a new space and renaming")
    func grouping() {
        let cs = [cand("a", .claude, project: "port42", branch: "nautilus", age: 60),
                  cand("b", .claude, project: "port42", branch: "phase4", age: 120),
                  cand("c", .codex, project: "kynee", branch: "main", age: 600),
                  cand("d", .claude, project: "scratch", branch: nil, age: 3 * 86400)]
        var s = SessionImport.Selection.initial(cs)
        #expect(s.groups.map(\.name) == ["port42", "kynee", "scratch"])
        #expect(s.groups[0].sessions == ["a", "b"])
        #expect(s.ticked == ["a", "b", "c"] && s.older == ["d"])
        s.move("c", to: s.groups[0].id)
        #expect(s.groups.map(\.name) == ["port42", "scratch"], "an emptied group goes")
        #expect(s.groups[0].sessions == ["a", "b", "c"])
        s.moveToNewGroup("b", named: "port42")
        #expect(s.groups.last?.name == "port42 2" && s.groups.last?.sessions == ["b"], "a new space never takes an existing name")
        s.rename(s.groups[0].id, to: "  work  ")
        #expect(s.groups[0].name == "work")
        s.toggle("d")
        let reqs = s.requests(cs)
        #expect(reqs.map(\.sessionId) == ["a", "c", "d", "b"])
        #expect(reqs.first { $0.sessionId == "a" }?.name == "port42-nautilus" && reqs.first { $0.sessionId == "d" }?.name == "scratch")
        #expect(reqs.first { $0.sessionId == "c" }?.space == "work")
    }

    func req(_ id: String, _ cli: SessionImport.CLI, space: String, name: String) -> SessionImport.Request {
        .init(sessionId: id, cli: cli, cwd: "/tmp", space: space, name: name)
    }

    @Test("bringing in: a companion per session in its space, whose terminal forks the session; names and spaces reused sensibly")
    func importing() throws {
        let w = try makeParityWorld()
        let person = w.state.currentUser!
        let results = try w.state.importSessions([req("claude-1", .claude, space: "port42 work", name: "port42-nautilus"),
                                                  req("codex-1", .codex, space: "port42 work", name: "port42-nautilus")], person: person)
        #expect(results.count == 2 && results[0].spaceId == results[1].spaceId, "one space for the group")
        let space = try #require(w.state.spaces.first { $0.id == results[0].spaceId })
        #expect(space.name == "port42-work")
        #expect(results.map(\.companion) == ["port42-nautilus", "port42-nautilus-2"], "a second session gets its own name")
        let claude = try #require(w.state.companions.first { $0.displayName == "port42-nautilus" })
        #expect(claude.envVars?["PORT42_FORK_FROM"] == "claude-1" && claude.args == nil)
        let claudeTerm = try #require(w.state.portWindows.panels.first { w.state.terminal($0.terminalConfig, isFor: claude) })
        #expect(claudeTerm.terminalConfig?.env["PORT42_FORK_FROM"] == "claude-1", "the fork reaches the terminal's environment")
        #expect(claudeTerm.terminalConfig?.cwd == "/tmp")
        let codex = try #require(w.state.companions.first { $0.displayName == "port42-nautilus-2" })
        #expect(codex.args == ["fork", "codex-1"])
        let codexTerm = try #require(w.state.portWindows.panels.first { w.state.terminal($0.terminalConfig, isFor: codex) })
        let start = codexTerm.terminalConfig?.startupCommand ?? ""
        #expect(start.hasPrefix("codex fork codex-1 "), "\(start)")
        #expect(CLIHookProducer.isBriefedStart(start), "its first turn is the briefing, whose reply is not posted")
        // A later import into a space of the same name lands beside it.
        let again = try w.state.importSessions([req("claude-2", .claude, space: "Port42 Work", name: "other")], person: person)
        #expect(again[0].spaceId == space.id)
    }

    @Test("an imported Codex resumes its own fork after the first launch, in its command and its stored terminal")
    func codexSwitchesToResume() throws {
        let w = try makeParityWorld()
        let r = try w.state.importSessions([req("orig-9", .codex, space: "x", name: "cx")], person: w.state.currentUser!)
        let c = try #require(w.state.companions.first { $0.displayName == "cx" })
        let panel = try #require(w.state.portWindows.panels.first { w.state.terminal($0.terminalConfig, isFor: c) })
        w.state.noteSessionId("fork-7", config: panel.terminalConfig!, panelId: panel.id)
        #expect(w.state.companions.first { $0.id == c.id }?.args == ["resume", "fork-7"])
        let stored = w.state.portWindows.panels.first { $0.id == panel.id }?.terminalConfig?.startupCommand ?? ""
        #expect(stored.hasPrefix("codex resume fork-7 ") && !stored.contains("orig-9"), "\(stored)")
        #expect(CLIHookProducer.isBriefedStart(stored))
        // A later start reporting the same session changes nothing more.
        w.state.noteSessionId("fork-7", config: panel.terminalConfig!, panelId: panel.id)
        #expect(w.state.companions.first { $0.id == c.id }?.args == ["resume", "fork-7"])
        _ = r
    }

    @Test("after a first-run import the person lands in the first imported space, on its session")
    func landing() throws {
        let w = try makeParityWorld()
        let r = try w.state.importSessions([req("s1", .claude, space: "landing", name: "lander")], person: w.state.currentUser!)
        w.state.landOnImported(r)
        #expect(w.state.currentSpace?.id == r[0].spaceId)
        #expect(w.state.onboardingFocusPortId == r[0].portId && r[0].portId != nil)
    }
}

/// Echo's welcome names what setup brought in (GM, 2026-09-26: after "what is this place", which spaces
/// were made for you).
@Suite("Echo knows the imported sessions")
@MainActor
struct EchoImportedBriefTests {

    static let requests: [SessionImport.Request] = [
        .init(sessionId: "s1", cli: .claude, cwd: "/w/port42-native", space: "port42-native", name: "port42-native-nautilus"),
        .init(sessionId: "s2", cli: .codex, cwd: "/w/kynee", space: "kynee release", name: "kynee main"),
        .init(sessionId: "s3", cli: .claude, cwd: "/w/port42-native", space: "port42-native", name: "port42-native-phase4"),
    ]

    @Test("the note lists each space once, with who is waiting in it, as they would be mentioned")
    func note() {
        let n = AppState.echoImportedNote(Self.requests)
        #expect(n.contains("#port42-native: @port42-native-nautilus (claude), @port42-native-phase4 (claude)"))
        #expect(n.contains("#kynee release: @kynee%20main (codex)"))
        #expect(n.components(separatedBy: "#port42-native").count == 2, "a space listed twice")
        #expect(AppState.echoImportedNote([]) == "")
    }

    @Test("completeSetup puts it in echo's brief, and leaves no placeholder when nothing came in")
    func brief() throws {
        for imported in [Self.requests, []] {
            let db = try DatabaseService(inMemory: true)
            let state = AppState(db: db)
            let user = AppUser.createForTesting(displayName: "Gordon")
            try db.saveUser(user)
            state.currentUser = user
            state.completeSetup(displayName: "Gordon", cli: "claude", imported: imported)
            let echo = try #require(state.companions.first { $0.displayName == "echo" })
            let prompt = echo.systemPrompt ?? ""
            #expect(!prompt.contains("{{IMPORTED}}"))
            #expect(prompt.contains("#kynee release") == !imported.isEmpty)
            #expect(prompt.contains("it's their machine and their agent."))
        }
    }
}

@Suite("Session list says what the groups are")
struct SessionGroupingNoteTests {
    @Test("the list says it grouped the sessions into spaces, and how many")
    func note() {
        #expect(SessionImportList.groupingNote(spaces: 3).hasPrefix("port42 grouped them into 3 spaces for you"))
        #expect(SessionImportList.groupingNote(spaces: 1).contains("into one space"))
        #expect(SessionImportList.groupingNote(spaces: 2).contains("each # is a space"))
    }
}
