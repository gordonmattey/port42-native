import Foundation

/// Bring running sessions into Port42 (docs/plan-session-import.md). Step 1: find them.
///
/// Pure over a process list and the two CLIs' session logs, so it is tested without a running Claude
/// or Codex. `SessionImport.probe()` reads the real system. Nothing here needs a permission: the
/// window titles AppleScript can add (matched on `tty`) are an optional enrichment on top.
public enum SessionImport {

    public enum CLI: String, Equatable, Codable { case claude, codex }

    /// One process, as the probe sees it.
    public struct Proc: Equatable {
        public var pid: Int32
        public var ppid: Int32
        public var args: String
        public var cwd: String?
        public var tty: String?
        public var startedAt: Date?
        public init(pid: Int32, ppid: Int32, args: String, cwd: String? = nil, tty: String? = nil, startedAt: Date? = nil) {
            self.pid = pid; self.ppid = ppid; self.args = args; self.cwd = cwd; self.tty = tty; self.startedAt = startedAt
        }
    }

    /// A running session Port42 could bring in.
    public struct Candidate: Equatable, Identifiable {
        public var id: String { sessionId }
        public let cli: CLI
        public let pid: Int32
        public let cwd: String
        /// The repository (or folder) name: the default space.
        public let project: String
        public let branch: String?
        public let sessionId: String
        public let title: String
        public let lastActive: Date
        /// The app the terminal runs in ("Terminal", "iTerm2", "Ghostty"), for "close the originals".
        public let app: String?
        public let tty: String?
    }

    /// A session log on disk.
    struct LogFile: Equatable {
        let cli: CLI
        let sessionId: String
        let cwd: String
        let modified: Date
        let path: String
    }

    // MARK: - Which processes

    static func basename(_ s: Substring) -> String { String(s.split(separator: "/").last ?? s) }

    /// The CLI an interactive process runs, or nil. Codex runs as a `node` wrapper and its native
    /// binary; only the wrapper counts. Helpers (Claude's daemon, `codex exec`, MCP servers) are not
    /// sessions.
    static func cli(of p: Proc, byPid: [Int32: Proc]) -> CLI? {
        let words = p.args.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first else { return nil }
        let exe = basename(first)
        if exe == "claude" {
            let sub = words.dropFirst().first.map(String.init) ?? ""
            return ["daemon", "mcp", "doctor", "update", "config", "migrate-installer", "install"].contains(sub) ? nil : .claude
        }
        let codexWord: Substring? = exe == "node" ? words.dropFirst().first : (exe == "codex" ? first : nil)
        guard let cw = codexWord, basename(cw) == "codex" else { return nil }
        // The native binary under its node wrapper is the same session.
        if exe == "codex", let parent = byPid[p.ppid], parent.args.contains("/codex") || basename(parent.args.split(separator: " ").first ?? "") == "node" {
            return nil
        }
        let rest = words.drop { $0 != cw }.dropFirst()
        let sub = rest.first.map(String.init) ?? ""
        return ["exec", "app-server", "mcp", "mcp-server", "proto", "login", "logout", "completion"].contains(sub) ? nil : .codex
    }

    /// Port42 started this one: somewhere above it is a Port42 app (its terminals' shells are its
    /// children). Those are already in Port42.
    static func ownedByPort42(_ p: Proc, byPid: [Int32: Proc]) -> Bool {
        var cur: Proc? = byPid[p.ppid]
        var hops = 0
        while let c = cur, hops < 40 {
            if c.args.contains(".app/Contents/MacOS/Port42") { return true }
            cur = c.ppid == c.pid ? nil : byPid[c.ppid]
            hops += 1
        }
        return false
    }

    /// The app hosting the terminal, from the first `.app` above the process.
    static func hostApp(_ p: Proc, byPid: [Int32: Proc]) -> String? {
        var cur: Proc? = byPid[p.ppid]
        var hops = 0
        while let c = cur, hops < 40 {
            if let r = c.args.range(of: ".app/Contents/MacOS/") {
                let before = c.args[..<r.lowerBound]
                return String(before.split(separator: "/").last ?? before)
            }
            cur = c.ppid == c.pid ? nil : byPid[c.ppid]
            hops += 1
        }
        return nil
    }

    /// A session id named on the command line: `claude --resume X`, `--session-id X`, `-r X`,
    /// `codex resume X`, `codex fork X`.
    static func explicitSession(_ args: String, cli: CLI) -> String? {
        let w = args.split(separator: " ").map(String.init)
        for (i, word) in w.enumerated() where i + 1 < w.count {
            switch cli {
            case .claude where ["--resume", "-r", "--session-id"].contains(word): return w[i + 1]
            case .codex where ["resume", "fork"].contains(word) && !w[i + 1].hasPrefix("-"): return w[i + 1]
            default: continue
            }
        }
        return nil
    }

    // MARK: - Session logs

    /// Session logs changed in the last `days`, newest first. Claude: `~/.claude/projects/*/*.jsonl`,
    /// the cwd read from the log itself (not the folder name, as teleport does). Codex:
    /// `~/.codex/sessions/**.jsonl`, the id and cwd from its first record.
    /// `cwds`, when given, limits Claude's folders to the ones named after those directories (Claude
    /// names a project folder after its path), so a Mac with years of sessions is not read in full:
    /// on GM's Mac, reading them all took 15 s.
    static func logs(home: String, now: Date, days: Double = 7, cwds: Set<String>? = nil) -> [LogFile] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-days * 86400)
        var out: [LogFile] = []
        let claudeRoot = "\(home)/.claude/projects"
        let allDirs = (try? fm.contentsOfDirectory(atPath: claudeRoot)) ?? []
        let dirs: [String] = {
            guard let cwds else { return allDirs }
            let slugs = Set(cwds.flatMap { [projectSlug($0), projectSlug(realpath($0))] })
            let named = allDirs.filter { slugs.contains($0) }
            // A folder named some other way (a future naming rule) is found by reading them all.
            return named.count >= Set(cwds.map(projectSlug)).count ? named : allDirs
        }()
        for dir in dirs {
            let d = "\(claudeRoot)/\(dir)"
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".jsonl") {
                let path = "\(d)/\(f)"
                guard let m = modified(path), m >= cutoff, let cwd = firstValue("cwd", in: path) else { continue }
                out.append(LogFile(cli: .claude, sessionId: String(f.dropLast(6)), cwd: cwd, modified: m, path: path))
            }
        }
        let codexRoot = "\(home)/.codex/sessions"
        if let e = fm.enumerator(atPath: codexRoot) {
            while let rel = e.nextObject() as? String {
                guard rel.hasSuffix(".jsonl") else { continue }
                let path = "\(codexRoot)/\(rel)"
                guard let m = modified(path), m >= cutoff,
                      let line = firstLine(path), let data = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let p = o["payload"] as? [String: Any],
                      let id = (p["session_id"] ?? p["id"]) as? String, let cwd = p["cwd"] as? String else { continue }
                out.append(LogFile(cli: .codex, sessionId: id, cwd: cwd, modified: m, path: path))
            }
        }
        return out.sorted { $0.modified > $1.modified }
    }

    /// Claude's folder name for a directory: every character but a letter or digit as a dash.
    static func projectSlug(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func firstLine(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let chunk = h.readData(ofLength: 256 * 1024)
        return String(decoding: chunk, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    /// The first `"key":"value"` in a log's opening lines.
    static func firstValue(_ key: String, in path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let text = String(decoding: h.readData(ofLength: 256 * 1024), as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let v = o[key] as? String, !v.isEmpty else { continue }
            return v
        }
        return nil
    }

    /// What the session is about: Claude's own title for it, else the person's first request.
    static func title(of log: LogFile) -> String {
        // The head for the first request, the tail for Claude's latest title: never the whole file,
        // which for a long session is many megabytes.
        guard let text = headAndTail(log.path, head: 256 * 1024, tail: 512 * 1024) else { return "" }
        var first: String?
        var aiTitle: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch log.cli {
            case .claude:
                if o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String { aiTitle = t }
                if first == nil, o["type"] as? String == "user", let m = o["message"] as? [String: Any] {
                    if let s = m["content"] as? String { first = s }
                    else if let parts = m["content"] as? [[String: Any]], let t = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String { first = t }
                }
            case .codex:
                guard first == nil, let p = o["payload"] as? [String: Any] else { continue }
                if p["type"] as? String == "user_message", let m = p["message"] as? String { first = m }
                else if o["type"] as? String == "response_item", p["role"] as? String == "user",
                        let c = p["content"] as? [[String: Any]], let t = c.first?["text"] as? String,
                        !t.hasPrefix("#"), !t.hasPrefix("<") { first = t }
            }
        }
        let t = (aiTitle ?? first ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return t.count > 60 ? String(t.prefix(59)) + "…" : t
    }

    static func headAndTail(_ path: String, head: Int, tail: Int) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        if size <= UInt64(head + tail) { return String(decoding: h.readDataToEndOfFile(), as: UTF8.self) }
        let first = h.readData(ofLength: head)
        try? h.seek(toOffset: size - UInt64(tail))
        let last = h.readDataToEndOfFile()
        // Cut to whole lines on both sides of the gap.
        let a = String(decoding: first, as: UTF8.self)
        let b = String(decoding: last, as: UTF8.self)
        let aLines = a.split(separator: "\n").dropLast().joined(separator: "\n")
        let bLines = b.split(separator: "\n").dropFirst().joined(separator: "\n")
        return aLines + "\n" + bLines
    }

    // MARK: - Where it runs

    /// The repository root above `cwd` (a `.git` folder or a worktree's `.git` file), else nil.
    static func gitRoot(_ cwd: String) -> String? {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return nil }
            dir = up
        }
        return nil
    }

    /// The checked-out branch, read from HEAD (a worktree's `.git` is a file naming its git dir).
    static func branch(_ cwd: String) -> String? {
        guard let root = gitRoot(cwd) else { return nil }
        let dotGit = "\(root)/.git"
        var gitDir = dotGit
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), !isDir.boolValue,
           let s = try? String(contentsOfFile: dotGit, encoding: .utf8),
           let r = s.range(of: "gitdir:") {
            gitDir = s[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let head = try? String(contentsOfFile: "\(gitDir)/HEAD", encoding: .utf8) else { return nil }
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst("ref: refs/heads/".count)) : String(h.prefix(7))
    }

    /// The project a session belongs to: its repository's name, else its folder's. A worktree under
    /// `.claude/worktrees/` belongs to the repository that holds it.
    static func project(_ cwd: String) -> String {
        let root = gitRoot(cwd) ?? cwd
        if let r = root.range(of: "/.claude/worktrees/") {
            return URL(fileURLWithPath: String(root[..<r.lowerBound])).lastPathComponent
        }
        return URL(fileURLWithPath: root).lastPathComponent
    }

    // MARK: - Put together

    static func realpath(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }

    /// Every running Claude Code and Codex session Port42 did not start, with the session it is in,
    /// newest first. A process that names its session on the command line gets that one; otherwise
    /// it gets the newest log for its directory that no other process claimed.
    public static func find(procs: [Proc], home: String, now: Date = Date()) -> [Candidate] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let cwds = Set(procs.compactMap { p in cli(of: p, byPid: byPid) != nil ? p.cwd : nil })
        // No age limit: a session idle for weeks is still running, and its folders are few.
        let logs = logs(home: home, now: now, days: 3650, cwds: cwds)
        var claimed = Set<String>()
        var out: [Candidate] = []
        let running = procs.compactMap { p -> (Proc, CLI)? in
            guard let c = cli(of: p, byPid: byPid), p.cwd != nil, !ownedByPort42(p, byPid: byPid) else { return nil }
            return (p, c)
        }
        // Explicit ids first, so a guessed match never takes a session someone named.
        let ordered = running.sorted { (explicitSession($0.0.args, cli: $0.1) != nil ? 0 : 1) < (explicitSession($1.0.args, cli: $1.1) != nil ? 0 : 1) }
        for (p, c) in ordered {
            let cwd = realpath(p.cwd!)
            let log: LogFile?
            if let id = explicitSession(p.args, cli: c) {
                log = logs.first { $0.cli == c && $0.sessionId == id }
            } else {
                log = logs.first { $0.cli == c && !claimed.contains($0.sessionId) && realpath($0.cwd) == cwd }
            }
            guard let l = log, !claimed.contains(l.sessionId) else { continue }
            claimed.insert(l.sessionId)
            out.append(Candidate(cli: c, pid: p.pid, cwd: cwd, project: project(cwd), branch: branch(cwd),
                                 sessionId: l.sessionId, title: title(of: l), lastActive: l.modified,
                                 app: hostApp(p, byPid: byPid), tty: p.tty))
        }
        return out.sorted { $0.lastActive > $1.lastActive }
    }

    // MARK: - Grouping (step 2)

    /// A space the import will make (or use), with the sessions going into it.
    public struct Group: Equatable, Identifiable {
        public let id: String
        public var name: String
        public var sessions: [String]
    }

    /// What the person has chosen: the groups, and which sessions are ticked.
    public struct Selection: Equatable {
        public var groups: [Group]
        public var ticked: Set<String>
        public var older: Set<String>

        /// One group per project, the most recently active first; sessions active in the last day
        /// ticked, older ones unticked (and shown collapsed).
        public static func initial(_ cs: [Candidate], now: Date = Date(), recent: TimeInterval = 86400) -> Selection {
            var order: [String] = []
            var byProject: [String: [Candidate]] = [:]
            for c in cs.sorted(by: { $0.lastActive > $1.lastActive }) {
                if byProject[c.project] == nil { order.append(c.project) }
                byProject[c.project, default: []].append(c)
            }
            let groups = order.map { Group(id: "g-\($0)", name: $0, sessions: byProject[$0]!.map(\.sessionId)) }
            let recentIds = Set(cs.filter { now.timeIntervalSince($0.lastActive) <= recent }.map(\.sessionId))
            return Selection(groups: groups, ticked: recentIds, older: Set(cs.map(\.sessionId)).subtracting(recentIds))
        }

        /// Move a session to another group (a drag onto its heading). An emptied group goes.
        public mutating func move(_ session: String, to groupId: String) {
            guard groups.contains(where: { $0.id == groupId }) else { return }
            for i in groups.indices { groups[i].sessions.removeAll { $0 == session } }
            if let i = groups.firstIndex(where: { $0.id == groupId }) { groups[i].sessions.append(session) }
            groups.removeAll { $0.sessions.isEmpty }
        }

        /// Move a session into a new space of its own (a drag onto "new space").
        public mutating func moveToNewGroup(_ session: String, named name: String) {
            let id = "g-new-\(UUID().uuidString.prefix(8))"
            groups.append(Group(id: id, name: uniqueName(name), sessions: []))
            move(session, to: id)
        }

        public mutating func rename(_ groupId: String, to name: String) {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, let i = groups.firstIndex(where: { $0.id == groupId }) else { return }
            groups[i].name = n
        }

        public mutating func toggle(_ session: String) {
            if ticked.contains(session) { ticked.remove(session) } else { ticked.insert(session) }
        }

        func uniqueName(_ base: String) -> String {
            var n = base, k = 2
            while groups.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { n = "\(base) \(k)"; k += 1 }
            return n
        }

        /// The ticked sessions as import requests, in group order.
        public func requests(_ cs: [Candidate]) -> [Request] {
            let byId = Dictionary(cs.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
            return groups.flatMap { g in
                g.sessions.filter { ticked.contains($0) }.compactMap { id -> Request? in
                    guard let c = byId[id] else { return nil }
                    return Request(sessionId: id, cli: c.cli, cwd: c.cwd, space: g.name,
                                   name: c.branch.map { "\(c.project)-\($0)" } ?? c.project)
                }
            }
        }
    }

    /// One session to bring in: which, from where, into which space, under what companion name.
    public struct Request: Codable, Equatable {
        public let sessionId: String
        public let cli: CLI
        public let cwd: String
        public let space: String
        public let name: String
    }

    // MARK: - The real system

    /// The running processes, with each CLI process's working directory. `ps` for the table, `lsof`
    /// for the directories of the few that are Claude or Codex.
    public static func probe() -> [Proc] {
        guard let table = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,lstart=,args="]) else { return [] }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var procs: [Proc] = []
        for line in table.split(separator: "\n") {
            let w = line.split(separator: " ", omittingEmptySubsequences: true)
            guard w.count >= 9, let pid = Int32(w[0]), let ppid = Int32(w[1]) else { continue }
            let tty = w[2] == "??" ? nil : String(w[2])
            let started = fmt.date(from: w[3...7].joined(separator: " "))
            procs.append(Proc(pid: pid, ppid: ppid, args: w[8...].joined(separator: " "), tty: tty, startedAt: started))
        }
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = procs.filter { cli(of: $0, byPid: byPid) != nil }.map { String($0.pid) }
        guard !wanted.isEmpty, let lsof = run("/usr/sbin/lsof", ["-a", "-p", wanted.joined(separator: ","), "-d", "cwd", "-Fpn"]) else { return procs }
        var cwds: [Int32: String] = [:]
        var current: Int32?
        for l in lsof.split(separator: "\n") {
            if l.hasPrefix("p") { current = Int32(l.dropFirst()) }
            else if l.hasPrefix("n"), let c = current { cwds[c] = String(l.dropFirst()) }
        }
        return procs.map { var p = $0; p.cwd = cwds[p.pid]; return p }
    }

    static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
