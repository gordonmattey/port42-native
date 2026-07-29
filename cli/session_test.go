package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writeTranscript creates <home>/.claude/projects/<dir>/<id>.jsonl with the given lines and a
// deterministic mtime, so newest-first ordering is testable.
func writeTranscript(t *testing.T, home, dir, id string, age time.Duration, lines ...string) string {
	t.Helper()
	full := filepath.Join(home, ".claude", "projects", dir)
	if err := os.MkdirAll(full, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(full, id+".jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	when := time.Now().Add(-age)
	if err := os.Chtimes(path, when, when); err != nil {
		t.Fatal(err)
	}
	return path
}

func cwdLine(cwd string) string {
	b, _ := json.Marshal(map[string]any{"type": "user", "cwd": cwd})
	return string(b)
}

func TestProjectSlug(t *testing.T) {
	cases := []struct{ cwd, want string }{
		{"/Users/gordon/code", "-Users-gordon-code"},
		{"/", "-"},
		{"/a/b-c/d", "-a-b-c-d"},
	}
	for _, c := range cases {
		if got := projectSlug(c.cwd); got != c.want {
			t.Errorf("projectSlug(%q) = %q, want %q", c.cwd, got, c.want)
		}
	}
}

func TestTranscriptCwd(t *testing.T) {
	home := t.TempDir()

	// The opening record often carries no cwd, so the scan must look past it.
	p := writeTranscript(t, home, "proj", "s1", 0,
		`{"type":"mode","sessionId":"s1"}`,
		cwdLine("/Users/gordon/code"))
	if got := transcriptCwd(p); got != "/Users/gordon/code" {
		t.Errorf("transcriptCwd = %q, want /Users/gordon/code", got)
	}

	// A transcript that records no cwd at all yields "" rather than a false match.
	p2 := writeTranscript(t, home, "proj", "s2", 0, `{"type":"mode"}`)
	if got := transcriptCwd(p2); got != "" {
		t.Errorf("transcriptCwd on a cwd-less transcript = %q, want empty", got)
	}

	// Lines far larger than bufio's 64KB default must not abort the scan. That failure mode
	// would read as "no cwd here" and silently drop the session from the fallback path.
	huge := `{"type":"assistant","text":"` + strings.Repeat("x", 200_000) + `"}`
	p3 := writeTranscript(t, home, "proj", "s3", 0, huge, cwdLine("/Users/gordon/big"))
	if got := transcriptCwd(p3); got != "/Users/gordon/big" {
		t.Errorf("transcriptCwd past a 200KB line = %q, want /Users/gordon/big", got)
	}
}

func TestSessionsForCwdFastPath(t *testing.T) {
	home := t.TempDir()
	cwd := "/Users/gordon/code"
	slug := projectSlug(cwd)

	writeTranscript(t, home, slug, "old-session", 2*time.Hour, cwdLine(cwd))
	writeTranscript(t, home, slug, "new-session", 1*time.Minute, cwdLine(cwd))

	got := SessionsForCwd(home, cwd)
	if len(got) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(got))
	}
	if got[0].ID != "new-session" {
		t.Errorf("newest first: got %q, want new-session", got[0].ID)
	}
}

func TestSessionsForCwdFallsBackToRecordedCwd(t *testing.T) {
	home := t.TempDir()
	cwd := "/Users/gordon/code"

	// The slug directory does not exist, standing in for claude changing its naming rule. The
	// transcript still records where it ran, so resolution must still find it.
	writeTranscript(t, home, "some-other-naming-scheme", "found-me", time.Minute, cwdLine(cwd))
	// A session from a different directory must not be picked up.
	writeTranscript(t, home, "elsewhere", "wrong-dir", time.Second, cwdLine("/Users/gordon/other"))

	got := SessionsForCwd(home, cwd)
	if len(got) != 1 {
		t.Fatalf("expected 1 session, got %d: %+v", len(got), got)
	}
	if got[0].ID != "found-me" {
		t.Errorf("got %q, want found-me", got[0].ID)
	}
}

func TestSessionsForCwdEmpty(t *testing.T) {
	home := t.TempDir()
	if got := SessionsForCwd(home, "/nowhere"); len(got) != 0 {
		t.Errorf("expected no sessions, got %+v", got)
	}
}

func TestSessionsIgnoresEmptyTranscripts(t *testing.T) {
	home := t.TempDir()
	cwd := "/Users/gordon/code"
	slug := projectSlug(cwd)

	// A zero-byte transcript is not resumable; offering it would produce a port that fails.
	writeTranscript(t, home, slug, "empty", time.Minute)
	if err := os.Truncate(filepath.Join(home, ".claude", "projects", slug, "empty.jsonl"), 0); err != nil {
		t.Fatal(err)
	}
	writeTranscript(t, home, slug, "real", time.Hour, cwdLine(cwd))

	got := SessionsForCwd(home, cwd)
	if len(got) != 1 || got[0].ID != "real" {
		t.Errorf("expected only the non-empty session, got %+v", got)
	}
}

func TestSessionExists(t *testing.T) {
	home := t.TempDir()
	writeTranscript(t, home, "anywhere", "abc123", time.Minute, cwdLine("/tmp"))

	if !SessionExists(home, "abc123") {
		t.Error("expected abc123 to be found under any project dir")
	}
	if SessionExists(home, "nope") {
		t.Error("expected an unknown id to be absent")
	}
}

func TestResolveSession(t *testing.T) {
	home := t.TempDir()
	cwd := "/Users/gordon/code"
	writeTranscript(t, home, projectSlug(cwd), "newest", time.Minute, cwdLine(cwd))
	writeTranscript(t, home, "elsewhere", "explicit-one", time.Hour, cwdLine("/other"))

	got, err := resolveSession(home, cwd, "")
	if err != nil || got != "newest" {
		t.Errorf("default resolution = %q, %v; want newest", got, err)
	}

	// An explicit id wins even when it belongs to a different directory.
	got, err = resolveSession(home, cwd, "explicit-one")
	if err != nil || got != "explicit-one" {
		t.Errorf("explicit resolution = %q, %v; want explicit-one", got, err)
	}

	if _, err = resolveSession(home, cwd, "does-not-exist"); err == nil {
		t.Error("expected an error for an unknown explicit session id")
	}

	// No session for this directory is a normal outcome: start fresh, do not fail.
	got, err = resolveSession(home, "/untouched", "")
	if err != nil || got != "" {
		t.Errorf("empty-directory resolution = %q, %v; want \"\", nil", got, err)
	}
}

func TestBuildOptionsForkSession(t *testing.T) {
	// Resuming MUST carry --fork-session. Without it the shim's injected --session-id makes
	// claude exit 1 (verified against the real CLI, see docs/plan-teleport.md section 3).
	opts := buildOptions("/tmp/x", "sess-1", Space{})
	args, ok := opts["args"].([]string)
	if !ok {
		t.Fatalf("args missing or wrong type: %#v", opts["args"])
	}
	want := []string{"--resume", "sess-1", "--fork-session"}
	if len(args) != len(want) {
		t.Fatalf("args = %v, want %v", args, want)
	}
	for i := range want {
		if args[i] != want[i] {
			t.Fatalf("args = %v, want %v", args, want)
		}
	}
	if opts["type"] != "terminal" || opts["command"] != "claude" || opts["cwd"] != "/tmp/x" {
		t.Errorf("unexpected options: %#v", opts)
	}
	if _, present := opts["space_id"]; present {
		t.Error("space_id must be omitted when not requested, so the app picks the current space")
	}
}

func TestBuildOptionsFreshSession(t *testing.T) {
	// Nothing to resume: no args at all, so the port opens a plain claude in that directory.
	opts := buildOptions("/tmp/x", "", Space{ID: "space-9", Name: "nine"})
	if _, present := opts["args"]; present {
		t.Errorf("args must be absent with no session to resume, got %#v", opts["args"])
	}
	if opts["space_id"] != "space-9" {
		t.Errorf("space_id = %v, want space-9", opts["space_id"])
	}
}
