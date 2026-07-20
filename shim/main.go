// port42-claude-shim — a tiny PATH shim + hook notifier for the `claude` CLI inside
// Port42's native Ghostty terminals.
//
// Two modes, selected at runtime:
//
//   1. claude-injection mode  (invoked as `claude`, i.e. via a per-session symlink that
//      is first on PATH):
//        - If $PORT42_HOOKS_SOCKET is set, prepend `--settings <json>` registering Port42's
//          hooks, then exec the REAL claude resolved from $PORT42_CLAUDE_PATH.
//        - The registered hook command points back at THIS binary in `notify` mode, so the
//          shim itself translates Claude's raw hook payload into Port42's normalized event
//          vocabulary. The Swift receiver (TerminalHooksService) never sees Claude internals.
//
//   2. notify mode  (invoked as `port42-claude-shim notify <event>` by Claude when a hook
//      fires):
//        - Read Claude's compact-JSON hook payload from stdin (single line — read-safe).
//        - For `turnComplete` (Claude's `Stop`), the payload carries NO response text — only
//          `transcript_path`. So parse that JSONL and pull the last assistant turn's text.
//        - Write Port42-normalized JSON to $PORT42_HOOKS_SOCKET and exit. We write NOTHING
//          to stdout (stdout from a hook is interpreted by Claude as hook output / can block).
//
// No third-party deps. The approach is derived from public Claude Code hook docs +
// standard Unix patterns.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func main() {
	// notify mode: `port42-claude-shim notify <event>`
	if len(os.Args) >= 3 && os.Args[1] == "notify" {
		runNotify(os.Args[2])
		return
	}

	// Otherwise we are standing in for `claude` — either via the `claude` PATH symlink
	// (argv[0] basename == "claude") OR via the injected shell function that calls this
	// binary directly (argv[0] basename == "port42-claude-shim"). Both mean: inject
	// Port42 hooks and exec the real claude.
	runClaude()
}

// sanitizeEnv drops the Claude Code session-identity vars that leak in when a Port42 app is
// launched from inside a Claude Code session (docs/plan-companion-cwd.md). Left in place they make
// the spawned companion claude behave as a NESTED CHILD of the launching session, so it replies on
// screen but never persists its transcript at the path its Stop hook reports — every companion
// reply then reads empty. Port42 pins its own session via --session-id, so these must not survive.
// Everything else (OAuth token, PATH, HOME, PORT42_*) is preserved.
func sanitizeEnv(environ []string) []string {
	drop := map[string]bool{
		"CLAUDE_CODE_SESSION_ID":        true,
		"CLAUDE_CODE_CHILD_SESSION":     true,
		"CLAUDE_CODE_BRIDGE_SESSION_ID": true,
	}
	out := environ[:0:0]
	for _, kv := range environ {
		key := kv
		if i := strings.IndexByte(kv, '='); i >= 0 {
			key = kv[:i]
		}
		if drop[key] {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// sessionIDArgs returns the claude flags that pin Port42's per-port session id. Empty id → no
// flags. If a transcript for this id already exists, the session has run before → --resume;
// otherwise it is the first launch → --session-id (which errors if the id already exists). The
// transcript FILENAME is the session id, so a glob across all project dirs decides new-vs-resume
// without reproducing claude's cwd-to-project-slug rule.
func sessionIDArgs(home, id string) []string {
	if id == "" {
		return nil
	}
	matches, _ := filepath.Glob(filepath.Join(home, ".claude", "projects", "*", id+".jsonl"))
	if len(matches) > 0 {
		return []string{"--resume", id}
	}
	return []string{"--session-id", id}
}

// runClaude execs the real claude, injecting Port42 hooks via --settings when a hook socket
// is present. Resolves the real binary from $PORT42_CLAUDE_PATH so it can never re-exec itself.
func runClaude() {
	real := os.Getenv("PORT42_CLAUDE_PATH")
	if real == "" {
		fmt.Fprintln(os.Stderr, "port42-claude-shim: PORT42_CLAUDE_PATH not set; cannot locate the real claude")
		os.Exit(127)
	}

	argv := []string{real}
	if socket := os.Getenv("PORT42_HOOKS_SOCKET"); socket != "" {
		self, err := os.Executable()
		if err != nil || self == "" {
			self = os.Args[0]
		}
		argv = append(argv, "--settings", buildSettings(self))
		fmt.Fprintf(os.Stderr, "[port42-claude-shim] injecting hooks (socket=%s); exec %s\n", socket, real)
	} else {
		fmt.Fprintf(os.Stderr, "[port42-claude-shim] no PORT42_HOOKS_SOCKET; passthrough exec %s\n", real)
	}

	// Companion identity → append to the system prompt (no file mutation). Independent of hooks.
	if prompt := os.Getenv("PORT42_COMPANION_PROMPT"); prompt != "" {
		argv = append(argv, "--append-system-prompt", prompt)
	}
	// Per-port session id (docs/plan-companion-cwd.md): pin --session-id / --resume so command
	// companions sharing one space working dir land on DISTINCT transcripts. The app derives the
	// id (UUIDv5 of space:companion) and passes it via env; the shim decides new-vs-resume here
	// because it runs with the terminal's real cwd.
	if sid := os.Getenv("PORT42_CLAUDE_SESSION_ID"); sid != "" {
		home, _ := os.UserHomeDir()
		argv = append(argv, sessionIDArgs(home, sid)...)
	}
	argv = append(argv, os.Args[1:]...)

	if err := syscall.Exec(real, argv, sanitizeEnv(os.Environ())); err != nil {
		fmt.Fprintf(os.Stderr, "port42-claude-shim: exec %s failed: %v\n", real, err)
		os.Exit(127)
	}
}

// buildSettings produces the Claude Code `--settings` JSON registering Port42's hooks:
// Stop -> turnComplete (reply delivery) and SessionStart -> sessionStarted (launch detection).
// Note the nested matcher-block shape required by Claude Code:
//   {"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"..."}]}]}}
func buildSettings(selfPath string) string {
	type hookCmd struct {
		Type    string `json:"type"`
		Command string `json:"command"`
	}
	type matcherBlock struct {
		Matcher string    `json:"matcher"`
		Hooks   []hookCmd `json:"hooks"`
	}
	notify := func(event string) string {
		return shellQuote(selfPath) + " notify " + event
	}
	settings := map[string]any{
		"hooks": map[string]any{
			"Stop": []matcherBlock{{
				Matcher: "",
				Hooks:   []hookCmd{{Type: "command", Command: notify("turnComplete")}},
			}},
			// SessionStart lets the app notice a claude launch in ANY terminal (auto-register a
			// CLI companion, docs/summer2026-todo.md), not just ports spawned as named companions.
			"SessionStart": []matcherBlock{{
				Matcher: "",
				Hooks:   []hookCmd{{Type: "command", Command: notify("sessionStarted")}},
			}},
			// SessionEnd is the mirror: when claude exits, the auto-registered CLI companion leaves
			// the space (even if the terminal shell stays open).
			"SessionEnd": []matcherBlock{{
				Matcher: "",
				Hooks:   []hookCmd{{Type: "command", Command: notify("sessionEnded")}},
			}},
		},
	}
	b, err := json.Marshal(settings)
	if err != nil {
		return "{}"
	}
	return string(b)
}

// shellQuote single-quotes a string for safe use inside a shell command line (Claude runs
// the hook `command` via a shell).
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// normalizedEvent is Port42's wire format on the hooks socket. The Swift receiver decodes
// exactly this — it has no knowledge of Claude's raw payload shape.
type normalizedEvent struct {
	Event     string `json:"event"`
	Text      string `json:"text,omitempty"`
	ExitCode  int    `json:"exitCode"`
	Tool      string `json:"tool,omitempty"`
	Input     string `json:"input,omitempty"`
	Output    string `json:"output,omitempty"`
	Prompt    string `json:"prompt,omitempty"`
	SessionID string `json:"sessionId,omitempty"`
	// Diagnostics for the "reply on screen but never posts" bug: the transcript the Stop
	// hook handed us and its size on disk, carried to the app log over the same socket the
	// event uses (the shim's own stderr does not reach the app).
	Transcript      string `json:"transcript,omitempty"`
	TranscriptBytes int64  `json:"transcriptBytes,omitempty"`
}

// runNotify reads Claude's raw hook payload from stdin, translates it to a normalized event,
// and writes it to the hooks socket.
func runNotify(event string) {
	socket := os.Getenv("PORT42_HOOKS_SOCKET")
	if socket == "" {
		return
	}

	raw, _ := io.ReadAll(os.Stdin)
	var payload map[string]any
	_ = json.Unmarshal(raw, &payload)

	out := normalizedEvent{Event: event}
	if sid, ok := payload["session_id"].(string); ok {
		out.SessionID = sid
	}
	switch event {
	case "turnComplete":
		// The Stop payload carries no response text — read the transcript for it.
		// The final assistant message can lag the Stop hook by a few ms (the
		// transcript is flushed asynchronously), so poll briefly until non-empty.
		tp, _ := payload["transcript_path"].(string)
		if tp != "" {
			out.Text = lastAssistantTextWithRetry(tp)
		}
		// Carry the transcript path + size to the app log (see struct note): an empty post
		// is then one line naming the file the hook pointed at and whether it had bytes.
		out.Transcript = tp
		if fi, statErr := os.Stat(tp); statErr == nil {
			out.TranscriptBytes = fi.Size()
		}
	case "toolStarting", "toolFinished":
		if tn, ok := payload["tool_name"].(string); ok {
			out.Tool = tn
		}
		// tool input/output translation is wired in a later step.
	}

	data, err := json.Marshal(out)
	if err != nil {
		return
	}
	conn, err := net.Dial("unix", socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[port42-claude-shim] notify: dial %s failed: %v\n", socket, err)
		return
	}
	defer conn.Close()
	_, _ = conn.Write(data)
}

// lastAssistantTextWithRetry polls the transcript until the last assistant turn has text,
// tolerating the brief async flush lag between the Stop hook firing and the final assistant
// message landing on disk. Bounded so a genuinely empty reply can't hang the hook.
func lastAssistantTextWithRetry(path string) string {
	for i := 0; i < 20; i++ {
		if t := lastAssistantText(path); t != "" {
			return t
		}
		time.Sleep(50 * time.Millisecond)
	}
	return lastAssistantText(path)
}

// lastAssistantText reads a Claude Code transcript JSONL and returns the assistant reply for
// the CURRENT turn: the last non-empty assistant text that appears AFTER the most recent user
// message. This avoids an off-by-one — when the Stop hook fires, Claude Code may not have
// flushed THIS turn's assistant message yet, so the overall "last assistant" entry can still be
// the PREVIOUS turn's reply. Returning "" until the assistant-after-last-user exists lets the
// retry loop wait for the flush rather than delivering a stale, lagged reply.
// (Each injected space message becomes a `user` entry, so "after the last user" = this turn.)
func lastAssistantText(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	// Transcript lines can be large (tool outputs); raise the line cap well above the default 64KB.
	scanner.Buffer(make([]byte, 0, 1024*1024), 32*1024*1024)

	type turn struct{ role, text string }
	var turns []turn
	for scanner.Scan() {
		var entry struct {
			Type    string `json:"type"`
			Message struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
			continue
		}
		role := entry.Type
		if role == "" {
			role = entry.Message.Role
		}
		turns = append(turns, turn{role: role, text: extractText(entry.Message.Content)})
	}

	// Most recent user message = the turn we're answering.
	lastUser := -1
	for i, t := range turns {
		if t.role == "user" {
			lastUser = i
		}
	}

	// Last non-empty assistant text AFTER that user message = this turn's reply.
	last := ""
	for i := lastUser + 1; i < len(turns); i++ {
		if turns[i].role == "assistant" {
			if s := strings.TrimSpace(turns[i].text); s != "" {
				last = s
			}
		}
	}
	return strings.TrimSpace(last)
}

// extractText pulls plain text out of a message `content` field, which is either a bare
// string or an array of content blocks ({"type":"text","text":"..."} among tool_use etc).
func extractText(content json.RawMessage) string {
	if len(content) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(content, &s); err == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(content, &blocks); err == nil {
		var b strings.Builder
		for _, blk := range blocks {
			if blk.Type == "text" {
				b.WriteString(blk.Text)
			}
		}
		return b.String()
	}
	return ""
}
