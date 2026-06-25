package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
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
