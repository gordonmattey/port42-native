import Testing
import Foundation
@testable import Port42Lib

/// **Port42's hooks are ADDED to the user's codex config, not swapped in for it** (2026-07-31).
///
/// Reported live by GM: every codex launch printed
///
///     Ignored unsupported project-local config keys in /Users/gordon/.codex/config.toml: notify.
///
/// `CODEX_HOME` points codex at a directory of our making and we owned `config.toml` outright, so
/// codex never loaded the real one as its USER config. A Port42 terminal's cwd is often the home
/// directory, so codex then found `$HOME/.codex/config.toml` as a PROJECT-LOCAL file, where only a
/// subset of keys is legal. The warning named one key; the loss was the whole file — GM's is 62
/// lines and 14 tables.
///
/// The trap this suite exists for: the obvious fix, appending our block to the user's file, produces
/// a config codex REJECTS, because TOML forbids redefining a table and the user already declares
/// both `[features]` and `[projects."<home>"]`. So those two are merged in place.
@Suite("Codex config merge — the user's settings survive Port42's hooks")
struct CodexConfigMergeTests {

    /// A realistic slice of GM's actual config: the root key that triggered the report, plus both
    /// tables that collide with ours, plus material that must come through untouched.
    static let userConfig = """
    notify = ["/Users/gordon/.codex/computer-use/Client.app/Contents/MacOS/Client", "turn-ended"]

    [marketplaces.openai-bundled]
    kind = "bundled"

    [plugins."browser@openai-bundled"]
    enabled = true

    [features]
    web_search = true

    [mcp_servers.node_repl]
    command = "node"

    [desktop]
    theme = "dark"

    [projects."/Users/gordon"]
    trust_level = "untrusted"

    [tui.model_availability_nux]
    seen = true
    """

    // MARK: - setKey, the primitive

    @Test("an existing table gains the key, without a second table being declared")
    func insertsIntoExistingTable() {
        let out = CodexConfigMerge.setKey("hooks", to: "true", inTable: "features",
                                          of: Self.userConfig)
        #expect(out.contains("[features]"))
        // ONE [features]. Two is not a formatting nit: TOML rejects the document.
        #expect(out.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces) == "[features]" }.count == 1)
        #expect(out.contains("hooks = true"))
        #expect(out.contains("web_search = true"), "the user's own key in that table survives")
    }

    @Test("an existing key is REPLACED, not duplicated — TOML forbids the duplicate too")
    func replacesExistingKey() {
        // GM's config really does carry `trust_level = "untrusted"` for the home directory, so this
        // is the live case, not a contrived one.
        let out = CodexConfigMerge.setKey("trust_level", to: "\"trusted\"",
                                          inTable: "projects.\"/Users/gordon\"", of: Self.userConfig)
        #expect(out.contains("trust_level = \"trusted\""))
        #expect(!out.contains("trust_level = \"untrusted\""))
        #expect(out.components(separatedBy: "trust_level").count - 1 == 1)
    }

    @Test("a missing table is appended")
    func appendsMissingTable() {
        let out = CodexConfigMerge.setKey("trust_level", to: "\"trusted\"",
                                          inTable: "projects.\"/tmp/work\"", of: Self.userConfig)
        #expect(out.contains("[projects.\"/tmp/work\"]"))
        #expect(out.contains("trust_level = \"trusted\""))
        #expect(out.contains("notify = ["), "the user's document is otherwise intact")
    }

    @Test("a key in a LATER table is not mistaken for one in the target table")
    func respectsTableBoundaries() {
        // `[features]` is followed by other tables; inserting must land under [features] and must
        // not scan on into [mcp_servers.node_repl] and edit a key with a similar name there.
        let out = CodexConfigMerge.setKey("command", to: "\"ours\"", inTable: "features",
                                          of: Self.userConfig)
        #expect(out.contains("command = \"node\""), "the MCP server's own command is untouched")
        #expect(out.contains("command = \"ours\""))
    }

    // MARK: - The whole config

    @Test("the user's settings survive, and the colliding tables are merged not repeated")
    func mergedConfigKeepsEverything() {
        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/Users/gordon",
                                               userConfig: Self.userConfig)

        // The key that produced the report, and a sample of what was silently going with it.
        #expect(toml.contains("notify = ["))
        #expect(toml.contains("[marketplaces.openai-bundled]"))
        #expect(toml.contains("[plugins.\"browser@openai-bundled\"]"))
        #expect(toml.contains("[mcp_servers.node_repl]"))
        #expect(toml.contains("[desktop]"))
        #expect(toml.contains("[tui.model_availability_nux]"))

        // Ours, merged in.
        #expect(toml.contains("hooks = true"))
        #expect(toml.contains("trust_level = \"trusted\""))
        #expect(toml.contains("command = \"'/x/shim' notify sessionStarted\""))
        #expect(toml.contains("command = \"'/x/shim' notify turnComplete\""))

        // The rejection case: exactly one of each colliding table.
        let lines = toml.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.filter { $0 == "[features]" }.count == 1)
        #expect(lines.filter { $0 == "[projects.\"/Users/gordon\"]" }.count == 1)
    }

    @Test("with no user config the result is still a valid standalone config")
    func emptyUserConfigStillWorks() {
        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/tmp/work", userConfig: "")
        #expect(toml.contains("[features]"))
        #expect(toml.contains("hooks = true"))
        #expect(toml.contains("[projects.\"/tmp/work\"]"))
        #expect(toml.contains("trust_level = \"trusted\""))
        #expect(toml.contains("[[hooks.SessionStart]]"))
    }

    @Test("hook blocks are ARRAYS of tables, so they compose with any the user already has")
    func hookBlocksCompose() {
        let withOwnHooks = Self.userConfig + """

        [[hooks.Stop]]

        [[hooks.Stop.hooks]]
        type = "command"
        command = "mine"
        """
        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/Users/gordon",
                                               userConfig: withOwnHooks)
        // Both survive. `[[x]]` may legally repeat, which is exactly why these are appended while
        // `[features]` is merged.
        #expect(toml.contains("command = \"mine\""))
        #expect(toml.contains("command = \"'/x/shim' notify turnComplete\""))
    }

    // MARK: - Hook trust state, and why the config path must not move

    /// Codex records trust as `[hooks.state."<defining config path>:<event>:0:0"]`, written back
    /// into the config that defined the hook, and per its reference a hook it does not recognise is
    /// "marked for review and SKIPPED until trusted". With a per-port codex-home that path changed
    /// on every spawn, so codex met a brand-new hook every time and skipped it — which is why a
    /// codex companion never registered, across two versions and every config variation tried.
    @Test("the user's hook state is STRIPPED — it names a file that is not ours")
    func stripsUserHookState() {
        let polluted = Self.userConfig + """

        [hooks.state]

        [hooks.state."/<session-flags>/config.toml:session_start:0:0"]
        trusted_hash = "sha256:deadbeef"
        """
        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/Users/gordon",
                                               userConfig: polluted)
        // Observed live: this exact entry, left in ~/.codex/config.toml by a `-c` experiment, rode
        // the merge into a generated config where it referred to nothing.
        #expect(!toml.contains("/<session-flags>/"))
        #expect(!toml.contains("deadbeef"))
        #expect(toml.contains("notify = ["), "the rest of the user's config is untouched")
    }

    @Test("our OWN previous hook state is carried forward — this is what makes trust persist")
    func carriesForwardOwnHookState() {
        let previous = """
        [features]
        hooks = true

        [[hooks.SessionStart]]

        [hooks.state]

        [hooks.state."/stable/codex-home/config.toml:session_start:0:0"]
        trusted_hash = "sha256:cafebabe"
        """
        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/tmp/work",
                                               userConfig: Self.userConfig,
                                               previousConfig: previous)
        #expect(toml.contains("/stable/codex-home/config.toml:session_start:0:0"))
        #expect(toml.contains("cafebabe"))
        // And it lands AFTER the hooks it refers to.
        let stateIdx = toml.range(of: "[hooks.state")!.lowerBound
        let hookIdx = toml.range(of: "[[hooks.SessionStart]]")!.lowerBound
        #expect(hookIdx < stateIdx)
    }

    @Test("regenerating twice is idempotent — the same input yields the same document")
    func regenerationIsStable() {
        let first = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/tmp/work",
                                                userConfig: Self.userConfig)
        // A spawn re-reads its own previous config. If that round trip drifted, the hook's hash
        // would change and codex would demand review again — the exact failure being fixed.
        let second = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/tmp/work",
                                                 userConfig: Self.userConfig,
                                                 previousConfig: first)
        #expect(first == second)
    }

    @Test("partitioning splits hook state from everything else, and loses nothing")
    func partitionRoundTrips() {
        let doc = Self.userConfig + """

        [hooks.state]

        [hooks.state."/a/config.toml:stop:0:0"]
        trusted_hash = "sha256:1"

        [desktop2]
        x = 1
        """
        let (rest, state) = CodexConfigMerge.partitionHookState(doc)
        #expect(state.contains("/a/config.toml:stop:0:0"))
        #expect(!rest.contains("trusted_hash"))
        // A table AFTER the state block must return to the non-state side, or the scanner would
        // swallow the remainder of the document.
        #expect(rest.contains("[desktop2]"))
        #expect(rest.contains("x = 1"))
    }

    @Test("the real ~/.codex/config.toml on this machine merges without a duplicate table")
    func realUserConfigMerges() throws {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml")
        guard let real = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: NSHomeDirectory(),
                                               userConfig: real)
        // Every table header must be unique, or codex rejects the document. This is the assertion
        // that would have caught a naive append against a real config rather than a fixture.
        var seen = Set<String>()
        for line in toml.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), !t.hasPrefix("[["), t.hasSuffix("]") else { continue }
            #expect(!seen.contains(t), "duplicate table \(t) — codex would reject this")
            seen.insert(t)
        }
        #expect(toml.contains("hooks = true"))
    }
}
