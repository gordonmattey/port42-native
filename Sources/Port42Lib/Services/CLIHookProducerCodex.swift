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

            let home = "\(ctx.tempDir)/codex-home"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)

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
            let realHome = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
            let entries = (try? fm.contentsOfDirectory(atPath: realHome)) ?? []
            for entry in entries where entry != "config.toml" {
                let link = "\(home)/\(entry)"
                try? fm.removeItem(atPath: link)
                try? fm.createSymbolicLink(atPath: link, withDestinationPath: "\(realHome)/\(entry)")
            }

            let config = codexConfig(shimPath: shimPath, cwd: ctx.cwd)
            do {
                try config.write(toFile: "\(home)/config.toml", atomically: true, encoding: .utf8)
                out.env["CODEX_HOME"] = home
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
    static func codexConfig(shimPath: String, cwd: String) -> String {
        let quotedShim = shimPath.replacingOccurrences(of: "\"", with: "\\\"")
        let trust = trustedDirectories(for: cwd)
            .map { "[projects.\"\($0)\"]\ntrust_level = \"trusted\"\n" }
            .joined(separator: "\n")
        return """
        # Written by Port42 for one terminal session. Not the user's own config —
        # CODEX_HOME points here, and auth.json + sessions/ are symlinks to the real ~/.codex.
        [features]
        hooks = true

        \(trust)
        [[hooks.Stop]]

        [[hooks.Stop.hooks]]
        type = "command"
        command = "'\(quotedShim)' notify turnComplete"

        [[hooks.SessionStart]]

        [[hooks.SessionStart.hooks]]
        type = "command"
        command = "'\(quotedShim)' notify sessionStarted"

        """
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
