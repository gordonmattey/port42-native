import Foundation

// The codex producer. Every line here was learned from a live spike (2026-07-29) rather than from
// documentation, and several of them contradict it.
extension CLIHookProducer {

    /// Codex needs no interception. `CODEX_HOME` points it at a config directory of our making, and
    /// it reads the hooks itself — so there is no symlink, no shell function and no PATH prefix.
    /// That is why the producer abstraction prepares a SESSION rather than building settings: this
    /// mechanism could not be expressed as "return some JSON for the shim to inject".
    public static let codex = CLIHookProducer(
        name: "codex",
        matches: { $0.lowercased().contains("codex") },
        prepare: { ctx in
            var out = Output()
            guard let shimPath = ctx.shimPath else { return out }   // no notifier → no hooks

            let fm = FileManager.default
            let realHome = (ctx.home as NSString).appendingPathComponent(".codex")

            // NO REAL ~/.codex → PREPARE NOTHING (2026-07-31). This producer now runs for every
            // terminal, not only one started with `codex`, so it must be inert on a machine that
            // has never run codex. Pointing CODEX_HOME at a home with no onboarding state is not
            // neutral: the mirror comment below records that codex then treats it as a FIRST RUN,
            // sits on its setup screen and swallows every keystroke pushed at it. Manufacturing
            // that for users who do not use codex would be a worse bug than the one being fixed.
            guard fm.fileExists(atPath: realHome) else { return out }

            // STABLE, not per-port. Codex keys hook trust by the defining config's path, so a home
            // under `tempDir` gave every terminal a hook codex had never seen, which it reviewed
            // and skipped. `stableDir` is one directory per Port42 instance; falling back to
            // tempDir keeps tests and any caller that has not supplied one working.
            let home = "\((ctx.stableDir ?? ctx.tempDir))/codex-home"
            try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
            let previousConfig = (try? String(contentsOfFile: "\(home)/config.toml",
                                              encoding: .utf8)) ?? ""

            // MIRROR the user's real ~/.codex, entry by entry, and own ONLY config.toml.
            //
            // Linking just auth.json and sessions/ was not enough and the failure was silent: codex
            // ran, but a home with no onboarding state is a FIRST RUN, so it sat on its setup screen
            // and swallowed every keystroke pushed at it. No session file, no hooks, no error —
            // exactly like the trust-path bug one layer earlier.
            //
            // So the rule is inverted: everything is the user's real state unless we specifically
            // need to replace it. That also picks up whatever codex adds in future versions.
            //
            // Two of these matter enough to name. `auth.json`: without it every session demands a
            // fresh login. `sessions/`: the Stop payload's `transcript_path` lands INSIDE this home,
            // so leaving it unlinked strands transcripts in a temp dir and breaks `codex resume`.
            let entries = (try? fm.contentsOfDirectory(atPath: realHome)) ?? []
            for entry in entries where entry != "config.toml" {
                let link = "\(home)/\(entry)"
                try? fm.removeItem(atPath: link)
                try? fm.createSymbolicLink(atPath: link, withDestinationPath: "\(realHome)/\(entry)")
            }

            // The user's own config is the BASE, not something we replace. It is the one entry the
            // mirror above deliberately does not symlink, so it is the one that has to be carried
            // across by value.
            let userConfig = (try? String(contentsOfFile: "\(realHome)/config.toml",
                                          encoding: .utf8)) ?? ""
            let config = codexConfig(shimPath: shimPath, cwd: ctx.cwd, userConfig: userConfig,
                                     previousConfig: previousConfig)
            do {
                try config.write(toFile: "\(home)/config.toml", atomically: true, encoding: .utf8)
                out.env["CODEX_HOME"] = home
                // ALSO exported from the injected zshrc, not only set on the spawned process.
                // The process env alone covers `codex` as a startup command; it does not survive a
                // user's own startup files re-exporting CODEX_HOME, and the shell-level export is
                // what makes a codex TYPED into a plain terminal pick the hooked home up — the
                // claude-shaped guarantee, by the mechanism codex actually uses.
                out.shellLines = [
                    "# Port42: point codex at the hooked home, for a codex typed in later.",
                    "export CODEX_HOME='\(home.replacingOccurrences(of: "'", with: "'\\''"))'",
                    // NO `--dangerously-bypass-hook-trust`. It was tried and REMOVED the same day,
                    // because it makes things worse in a way that is easy to miss (2026-07-31).
                    //
                    // The `/hooks` table has three columns — Installed, Active, Review — and the
                    // flag addresses none of them. It suppresses the startup REVIEW PROMPT without
                    // enabling or trusting anything, so a hook that needs review silently never
                    // gets it: `1 0 1` forever, and the user is never asked. Running WITHOUT the
                    // flag is what produces the prompt, and answering it once writes
                    // `enabled = true` plus a `trusted_hash` into the config, which is the state
                    // that actually matters.
                    //
                    // Measured: with the flag, no prompt and no hook; without it, prompt, then
                    // `1 1 0` recorded in the stable config.
                    //
                    // TRUST IS ONE GATE, and it is why none of this worked (2026-07-31, measured).
                    //
                    // The config was right the whole time: `[features] hooks = true`, the event
                    // names, the three-level `[[hooks.X]]` / `[[hooks.X.hooks]]` shape, and an
                    // omitted matcher meaning "all sources" all match the published reference. What
                    // the reference also says is the part probing could not reveal:
                    //
                    //   "Codex records trust against the hook's current hash, so new or changed
                    //    hooks are marked for review and SKIPPED until trusted."
                    //
                    // SKIPPED — not prompted for. `/hooks` still lists the hook as active, which is
                    // what made this read as "codex ignores SessionStart" through two versions.
                    // And SessionStart fires before the TUI can ask anything, so the interactive
                    // grant can never arrive in time for the event that needs it.
                    //
                    // The flag is documented for exactly this case: "one-off automation that
                    // already vets hook sources outside Codex". Port42 GENERATED these hooks, so it
                    // is that automation. Measured: without it, zero sessionStarted across every
                    // run on 0.140.0 and 0.146.0; with it, the event lands and the companion
                    // registers with no interactive step at all.
                    //
                ]
            } catch {
                NSLog("[hooks] codex: failed to write config.toml: \(error)")
            }
            return out
        })

    /// The config that makes codex talk to Port42.
    ///
    /// FOUR things, and three of them were each a failed spike run before they were understood:
    ///
    /// - `[features] hooks = true` — hooks are off by default. (`codex_hooks` is the DEPRECATED
    ///   spelling; codex warns and ignores it.)
    /// - `[projects.<cwd>] trust_level` — without it codex refuses to start at all: "Not inside a
    ///   trusted directory". Nothing to do with hooks, and it looks exactly like hooks failing.
    /// - `[[hooks.Stop]]` — the turn-end event. Codex's hook config is the SAME SHAPE as claude's
    ///   `--settings` (matcher + hooks + type/command) and its event names overlap almost entirely.
    /// - the command — the shim in notify mode. It finds `PORT42_HOOKS_SOCKET` in the environment
    ///   codex inherits from the terminal, so nothing needs passing on the command line.
    ///
    /// Codex hooks fire in the INTERACTIVE TUI and not under `codex exec`, which is what made three
    /// separate probes read as "hooks are dead in this version". Port42 companions are interactive,
    /// so that limitation does not reach us.
    /// THE USER'S CONFIG IS THE BASE, and Port42's hooks are added to it (2026-07-31).
    ///
    /// This used to return a standalone document, which meant a Port42-wired codex ran with NONE of
    /// the user's own settings: `notify`, marketplaces, plugins, MCP servers, TUI state. Codex said
    /// so on every launch ("Ignored unsupported project-local config keys … : notify"), because with
    /// CODEX_HOME redirected it found `~/.codex/config.toml` only as a project-local file. The
    /// producer mirrors every entry in `~/.codex` except this one, so this was the single hole in
    /// "everything is the user's real state unless we specifically need to replace it".
    ///
    /// `[features]` and `[projects."<cwd>"]` are MERGED rather than appended, because the user may
    /// already declare both and TOML forbids redefining a table — a naive append yields a config
    /// codex rejects outright. The hook entries are arrays of tables, which may legally repeat, so
    /// those are appended and compose with any the user has of their own.
    static func codexConfig(shimPath: String, cwd: String, userConfig: String = "",
                            previousConfig: String = "") -> String {
        let quotedShim = shimPath.replacingOccurrences(of: "\"", with: "\\\"")

        // The user's config is re-read every time, so edits to it stay live. Its `[hooks.state]` is
        // STRIPPED: those entries name the file that defined the hook, so they mean nothing here.
        let userConfig = CodexConfigMerge.partitionHookState(userConfig).rest
        // Our own previous generation's hook state is CARRIED FORWARD. This is what makes trust
        // survive, and without it codex re-reviews (and therefore skips) the hook on every spawn.
        let carried = CodexConfigMerge.partitionHookState(previousConfig).state

        var toml = userConfig.isEmpty
            ? "# Written by Port42. CODEX_HOME points here; the rest of ~/.codex is symlinked.\n"
            : "# Port42 added its hooks to your ~/.codex/config.toml for this terminal session.\n"
              + "# Everything below is yours except the [features].hooks key, the project trust\n"
              + "# entries for this cwd, and the [[hooks.*]] blocks at the end.\n"
              + userConfig

        // Hooks are OFF by default, and this key may already exist in the user's own [features].
        toml = CodexConfigMerge.setKey("hooks", to: "true", inTable: "features", of: toml)

        // Codex's workspace sandbox blocks the network by default, and that includes loopback, so
        // every call a Codex companion made to Port42 failed and it concluded Port42 was not running
        // (GM's multi-agent test, 2026-09-25). A companion's whole job is calling Port42, so this
        // session's sandbox allows the network. Only this Port42 session's config; ~/.codex is not
        // touched.
        toml = CodexConfigMerge.setKey("network_access", to: "true", inTable: "sandbox_workspace_write", of: toml)

        // Without trust codex refuses to START, which looks exactly like hooks failing. Merged per
        // directory, so a project the user already trusts keeps its other settings.
        for dir in trustedDirectories(for: cwd) {
            toml = CodexConfigMerge.setKey("trust_level", to: "\"trusted\"",
                                           inTable: "projects.\"\(dir)\"", of: toml)
        }

        if !toml.hasSuffix("\n") { toml += "\n" }
        toml += """

        [[hooks.Stop]]

        [[hooks.Stop.hooks]]
        type = "command"
        command = "'\(quotedShim)' notify turnComplete"

        [[hooks.SessionStart]]

        [[hooks.SessionStart.hooks]]
        type = "command"
        command = "'\(quotedShim)' notify sessionStarted codex"

        """
        // Codex's own trust record goes LAST, after the hooks it refers to.
        return carried.isEmpty ? toml : toml + "\n" + carried + "\n"
    }

    /// Every path codex might CHECK trust against for one working directory.
    ///
    /// It resolves symlinks before looking, and on macOS `/tmp` is a symlink to `/private/tmp`, so
    /// a config that trusts only the path we were handed leaves codex refusing to start — silently,
    /// from Port42's side, because it exits before any hook can fire. This cost a live test: the
    /// port opened, the surface bound, and no process was ever there.
    ///
    /// `/var` → `/private/var` is the same shape, which is why this resolves rather than
    /// special-casing `/tmp`. Both forms are written because which one codex reports has varied.
    /// `realpath(3)`, NOT `URL.resolvingSymlinksInPath()` — Foundation deliberately declines to
    /// resolve `/tmp` and `/var`, which are the two paths this exists for.
    static func trustedDirectories(for cwd: String) -> [String] {
        let dir = cwd.isEmpty ? NSHomeDirectory() : cwd
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir, &buffer) != nil else { return [dir] }
        let resolved = String(cString: buffer)
        return resolved == dir ? [dir] : [dir, resolved]
    }
}
