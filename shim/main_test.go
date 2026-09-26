package main

import (
	"encoding/json"
	"fmt"
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
	want := `'/path/with space/port42-claude-shim' notify turnComplete claude`
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
	if got := parsed.Hooks.SessionStart[0].Hooks[0].Command; got != `'/x/port42-claude-shim' notify sessionStarted claude` {
		t.Fatalf("SessionStart command = %q", got)
	}
}

// SessionEnd -> sessionEnded is the mirror of SessionStart: the app removes the auto-registered
// CLI companion when claude exits.
func TestBuildSettingsSessionEnd(t *testing.T) {
	s := buildSettings("/x/port42-claude-shim")
	var parsed struct {
		Hooks struct {
			SessionEnd []struct {
				Hooks []struct {
					Command string `json:"command"`
				} `json:"hooks"`
			} `json:"SessionEnd"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal([]byte(s), &parsed); err != nil {
		t.Fatalf("settings not valid JSON: %v\n%s", err, s)
	}
	if len(parsed.Hooks.SessionEnd) != 1 || len(parsed.Hooks.SessionEnd[0].Hooks) != 1 {
		t.Fatalf("SessionEnd not wired: %s", s)
	}
	if got := parsed.Hooks.SessionEnd[0].Hooks[0].Command; got != `'/x/port42-claude-shim' notify sessionEnded claude` {
		t.Fatalf("SessionEnd command = %q", got)
	}
}

// Notification is the WAITING-FOR-YOU signal the peek feature runs on: claude raises it when a
// tool needs permission or the prompt has gone idle. Stop cannot substitute — it fires on every
// turn, so peeking on it would peek constantly.
func TestBuildSettingsNotification(t *testing.T) {
	s := buildSettings("/x/port42-claude-shim")
	var parsed struct {
		Hooks struct {
			Notification []struct {
				Hooks []struct {
					Command string `json:"command"`
				} `json:"hooks"`
			} `json:"Notification"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal([]byte(s), &parsed); err != nil {
		t.Fatalf("settings not valid JSON: %v\n%s", err, s)
	}
	if len(parsed.Hooks.Notification) != 1 || len(parsed.Hooks.Notification[0].Hooks) != 1 {
		t.Fatalf("Notification not wired: %s", s)
	}
	if got := parsed.Hooks.Notification[0].Hooks[0].Command; got != `'/x/port42-claude-shim' notify needsAttention claude` {
		t.Fatalf("Notification command = %q", got)
	}
}

// The reason travels with the event, so a peek can say WHAT is wanted rather than only that
// something is.
func TestNotifyCarriesTheAttentionReason(t *testing.T) {
	sock := fmt.Sprintf("/tmp/p42n%d.sock", time.Now().UnixNano()%1_000_000)
	defer os.Remove(sock)

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

	r, w, _ := os.Pipe()
	oldStdin := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = oldStdin }()
	go func() {
		w.Write([]byte(`{"session_id":"s9","hook_event_name":"Notification",` +
			`"message":"Claude needs your permission to use Bash"}`))
		w.Close()
	}()

	t.Setenv("PORT42_HOOKS_SOCKET", sock)
	runNotify("needsAttention", "")

	select {
	case msg := <-got:
		var ev normalizedEvent
		if err := json.Unmarshal([]byte(msg), &ev); err != nil {
			t.Fatalf("bad normalized JSON: %v (%s)", err, msg)
		}
		if ev.Event != "needsAttention" {
			t.Errorf("Event = %q", ev.Event)
		}
		if ev.Text != "Claude needs your permission to use Bash" {
			t.Errorf("Text = %q, want the notification message", ev.Text)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no event received")
	}
}

// notifyRoundTrip runs `runNotify` against a throwaway socket with `payload` on stdin and
// returns the normalized event the receiver got.
func notifyRoundTrip(t *testing.T, payload string) normalizedEvent {
	t.Helper()
	return notifyRoundTripAs(t, "turnComplete", "", payload)
}

// notifyRoundTripAs is notifyRoundTrip for any event, raised as `cli`.
func notifyRoundTripAs(t *testing.T, event, cli, payload string) normalizedEvent {
	t.Helper()
	// NOT t.TempDir(): its path plus a long test name overruns sockaddr_un.sun_path (104 on
	// macOS) and bind fails with EINVAL. Same limit TerminalHooksService keeps short ids for.
	sock := fmt.Sprintf("/tmp/p42t%d.sock", time.Now().UnixNano()%1_000_000)
	defer os.Remove(sock)

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
		buf := make([]byte, 8192)
		n, _ := c.Read(buf)
		got <- string(buf[:n])
	}()

	r, w, _ := os.Pipe()
	oldStdin := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = oldStdin }()
	go func() { w.Write([]byte(payload)); w.Close() }()

	t.Setenv("PORT42_HOOKS_SOCKET", sock)
	runNotify(event, cli)

	select {
	case msg := <-got:
		var ev normalizedEvent
		if err := json.Unmarshal([]byte(msg), &ev); err != nil {
			t.Fatalf("bad normalized JSON: %v (%s)", err, msg)
		}
		return ev
	case <-time.After(3 * time.Second):
		t.Fatal("no event received")
		return normalizedEvent{}
	}
}

// Codex's Stop payload hands over the reply text directly, so the shim must take it and never
// go near a transcript. Claude's carries no text at all — that difference is the whole reason
// the extraction branches, so both shapes are pinned here.
func TestNotifyPrefersSuppliedAssistantMessage(t *testing.T) {
	ev := notifyRoundTrip(t, `{"session_id":"cx1","hook_event_name":"Stop",`+
		`"last_assistant_message":"ok","transcript_path":"/nonexistent/should-not-be-read.jsonl"}`)

	if ev.Text != "ok" {
		t.Errorf("Text = %q, want the supplied last_assistant_message", ev.Text)
	}
	if ev.SessionID != "cx1" {
		t.Errorf("SessionID = %q, want cx1", ev.SessionID)
	}
}

// An EMPTY supplied message must not shadow the transcript. Otherwise a CLI that sets the field
// but leaves it blank on some turns would post nothing, which is the silent-empty-post class
// the transcript logging exists to catch.
func TestNotifyFallsBackWhenSuppliedMessageIsEmpty(t *testing.T) {
	tp := filepath.Join(t.TempDir(), "transcript.jsonl")
	_ = os.WriteFile(tp, []byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"from-transcript"}]}}`+"\n"), 0o644)

	ev := notifyRoundTrip(t, `{"session_id":"cx2","hook_event_name":"Stop",`+
		`"last_assistant_message":"","transcript_path":"`+tp+`"}`)

	if ev.Text != "from-transcript" {
		t.Errorf("Text = %q, want the transcript to be read when the field is empty", ev.Text)
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
	runNotify("turnComplete", "")

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

// A person's own session choice wins over Port42's pin (summer todo 2026-07-21: `claude --resume X`
// in a Port42 terminal failed, because the pin added a second session flag).
func TestUserChoosesSession(t *testing.T) {
	for _, args := range [][]string{{"--resume", "abc"}, {"-r"}, {"--continue"}, {"-c"}, {"--session-id", "x"},
		{"--resume=abc"}, {"--fork-session", "--resume", "abc"}, {"-p", "hi", "--continue"}} {
		if !userChoosesSession(args) {
			t.Fatalf("%v chooses a session", args)
		}
	}
	for _, args := range [][]string{{}, {"-p", "hello"}, {"--model", "opus"}, {"resume"}} {
		if userChoosesSession(args) {
			t.Fatalf("%v does not choose a session", args)
		}
	}
}

func TestSessionPinStepsAsideForTheUsersChoice(t *testing.T) {
	home := t.TempDir()
	if got := sessionPin(home, "sid-1", nil); len(got) != 2 || got[1] != "sid-1" {
		t.Fatalf("a bare launch gets the pin, got %v", got)
	}
	if got := sessionPin(home, "sid-1", []string{"--resume", "theirs"}); got != nil {
		t.Fatalf("the person's --resume must win, got %v", got)
	}
	if got := sessionPin(home, "", nil); got != nil {
		t.Fatalf("no pin without an id, got %v", got)
	}
}

func TestResumeDirReadsTheSessionsOwnDirectory(t *testing.T) {
	home := t.TempDir()
	proj := filepath.Join(home, ".claude", "projects", "-Users-someone")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	transcript := `{"type":"summary","summary":"x"}` + "\n" + `{"type":"user","cwd":"/Users/someone","message":{}}` + "\n"
	if err := os.WriteFile(filepath.Join(proj, "abc.jsonl"), []byte(transcript), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := resumeDir(home, "abc"); got != "/Users/someone" {
		t.Fatalf("resumeDir = %q, want the transcript's cwd", got)
	}
	if got := resumeDir(home, "missing"); got != "" {
		t.Fatalf("resumeDir for a missing session = %q, want empty", got)
	}
}

// A plain terminal where the person typed `codex` was registered as Claude, because the session
// start did not say which CLI raised it (2026-09-25). The hook now names its CLI.
func TestSessionStartNamesItsCLI(t *testing.T) {
	ev := notifyRoundTripAs(t, "sessionStarted", "codex", `{"session_id":"s1"}`)
	if ev.Event != "sessionStarted" || ev.CLI != "codex" {
		t.Fatalf("event = %+v, want sessionStarted from codex", ev)
	}
	if ev := notifyRoundTripAs(t, "sessionStarted", "", `{}`); ev.CLI != "" {
		t.Fatalf("an unnamed hook must not claim a CLI, got %q", ev.CLI)
	}
}
