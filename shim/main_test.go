package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLastAssistantText(t *testing.T) {
	dir := t.TempDir()
	tp := filepath.Join(dir, "transcript.jsonl")
	lines := `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say the word banana"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"banana"}]}}
`
	if err := os.WriteFile(tp, []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := lastAssistantText(tp); got != "banana" {
		t.Fatalf("lastAssistantText = %q, want %q", got, "banana")
	}
}

// Off-by-one regression: with multiple turns, return the reply to the LATEST user message,
// not an earlier turn's reply.
func TestLastAssistantTextLatestTurn(t *testing.T) {
	dir := t.TempDir()
	tp := filepath.Join(dir, "transcript.jsonl")
	lines := `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test 1"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply one"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test 2"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply two"}]}}
`
	if err := os.WriteFile(tp, []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := lastAssistantText(tp); got != "reply two" {
		t.Fatalf("lastAssistantText = %q, want %q (must be the latest turn, not lagged)", got, "reply two")
	}
}

// When the latest user message has no assistant reply flushed yet, return "" so the retry waits
// (rather than returning the PREVIOUS turn's reply).
func TestLastAssistantTextWaitsForCurrentTurn(t *testing.T) {
	dir := t.TempDir()
	tp := filepath.Join(dir, "transcript.jsonl")
	lines := `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test 1"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply one"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test 2"}]}}
`
	if err := os.WriteFile(tp, []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := lastAssistantText(tp); got != "" {
		t.Fatalf("lastAssistantText = %q, want empty (current turn not flushed → must not return prior reply)", got)
	}
}

// Command-companion cwd fix (docs/plan-companion-cwd.md, step 3): the shim pins Port42's
// per-port claude session id. First launch (no transcript yet) → --session-id; a later launch
// (transcript exists) → --resume; no id set → no flags. The transcript filename IS the id, so
// the existence check globs across all project dirs and is independent of claude's cwd-slug rule.
func TestSessionIDArgs(t *testing.T) {
	home := t.TempDir()
	id := "c1e275f0-629f-596e-9c45-72e34a8b0289"

	eq := func(got, want []string) {
		t.Helper()
		if len(got) != len(want) {
			t.Fatalf("sessionIDArgs = %v, want %v", got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("sessionIDArgs = %v, want %v", got, want)
			}
		}
	}

	// No id → no flags.
	if got := sessionIDArgs(home, ""); got != nil {
		t.Fatalf("sessionIDArgs(empty) = %v, want nil", got)
	}

	// No transcript yet → --session-id.
	eq(sessionIDArgs(home, id), []string{"--session-id", id})

	// Transcript exists under some project slug → --resume (slug-independent glob).
	proj := filepath.Join(home, ".claude", "projects", "-private-tmp-somewhere")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, id+".jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	eq(sessionIDArgs(home, id), []string{"--resume", id})
}

// A Port42 app launched from inside a Claude Code session inherits CLAUDE_CODE_SESSION_ID /
// _CHILD_SESSION / _BRIDGE_SESSION_ID and passes them to every claude it spawns, which then
// behaves as a NESTED CHILD of that session and does not persist its own transcript at the path
// its Stop hook reports (so companion replies read empty). The shim must scrub those before exec
// so each companion is an independent session. It must NOT drop the OAuth token or other vars.
func TestSanitizeEnv(t *testing.T) {
	in := []string{
		"HOME=/Users/gordon",
		"CLAUDE_CODE_SESSION_ID=0f398fb8-c202-4775-98d7-a9632f44b244",
		"CLAUDE_CODE_CHILD_SESSION=1",
		"CLAUDE_CODE_BRIDGE_SESSION_ID=session_015x",
		"CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-keep-me",
		"PATH=/usr/bin",
	}
	out := sanitizeEnv(in)
	joined := strings.Join(out, "\n")
	for _, bad := range []string{"CLAUDE_CODE_SESSION_ID=", "CLAUDE_CODE_CHILD_SESSION=", "CLAUDE_CODE_BRIDGE_SESSION_ID="} {
		if strings.Contains(joined, bad) {
			t.Fatalf("sanitizeEnv kept %q; want it dropped:\n%s", bad, joined)
		}
	}
	for _, keep := range []string{"HOME=/Users/gordon", "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-keep-me", "PATH=/usr/bin"} {
		if !strings.Contains(joined, keep) {
			t.Fatalf("sanitizeEnv dropped %q; want it kept:\n%s", keep, joined)
		}
	}
}

func TestExtractTextStringContent(t *testing.T) {
	if got := extractText(json.RawMessage(`"hello"`)); got != "hello" {
		t.Fatalf("extractText(string) = %q, want hello", got)
	}
}

func TestBuildSettingsShape(t *testing.T) {
	s := buildSettings("/path/with space/port42-claude-shim")
	var parsed struct {
		Hooks struct {
			Stop []struct {
				Matcher string `json:"matcher"`
				Hooks   []struct {
					Type    string `json:"type"`
					Command string `json:"command"`
				} `json:"hooks"`
			} `json:"Stop"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal([]byte(s), &parsed); err != nil {
		t.Fatalf("settings not valid JSON: %v\n%s", err, s)
	}
	if len(parsed.Hooks.Stop) != 1 || len(parsed.Hooks.Stop[0].Hooks) != 1 {
		t.Fatalf("unexpected Stop shape: %s", s)
	}
	cmd := parsed.Hooks.Stop[0].Hooks[0].Command
	want := `'/path/with space/port42-claude-shim' notify turnComplete`
	if cmd != want {
		t.Fatalf("command = %q, want %q", cmd, want)
	}
}

// SessionStart -> sessionStarted lets the app detect a claude launch in any terminal (the
// auto-register-CLI-companion hook, docs/summer2026-todo.md).
func TestBuildSettingsSessionStart(t *testing.T) {
	s := buildSettings("/x/port42-claude-shim")
	var parsed struct {
		Hooks struct {
			SessionStart []struct {
				Hooks []struct {
					Command string `json:"command"`
				} `json:"hooks"`
			} `json:"SessionStart"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal([]byte(s), &parsed); err != nil {
		t.Fatalf("settings not valid JSON: %v\n%s", err, s)
	}
	if len(parsed.Hooks.SessionStart) != 1 || len(parsed.Hooks.SessionStart[0].Hooks) != 1 {
		t.Fatalf("SessionStart not wired: %s", s)
	}
	if got := parsed.Hooks.SessionStart[0].Hooks[0].Command; got != `'/x/port42-claude-shim' notify sessionStarted` {
		t.Fatalf("SessionStart command = %q", got)
	}
}

func TestNotifyRoundTrip(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "h.sock")
	tp := filepath.Join(dir, "transcript.jsonl")
	_ = os.WriteFile(tp, []byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"banana"}]}}`+"\n"), 0o644)

	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	got := make(chan string, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		buf := make([]byte, 4096)
		n, _ := c.Read(buf)
		got <- string(buf[:n])
	}()

	// Feed the hook payload on stdin by swapping os.Stdin.
	r, w, _ := os.Pipe()
	oldStdin := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = oldStdin }()
	go func() {
		w.Write([]byte(`{"session_id":"abc","transcript_path":"` + tp + `","hook_event_name":"Stop"}`))
		w.Close()
	}()

	t.Setenv("PORT42_HOOKS_SOCKET", sock)
	runNotify("turnComplete")

	select {
	case msg := <-got:
		var ev normalizedEvent
		if err := json.Unmarshal([]byte(msg), &ev); err != nil {
			t.Fatalf("bad normalized JSON: %v (%s)", err, msg)
		}
		if ev.Event != "turnComplete" || ev.Text != "banana" || ev.SessionID != "abc" {
			t.Fatalf("unexpected event: %+v", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for socket message")
	}
}
