package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Session is one resumable Claude Code conversation on disk. The transcript FILENAME is the
// session id, which is what `claude --resume` takes.
type Session struct {
	ID      string
	Path    string
	Cwd     string
	ModTime time.Time
}

// projectSlug is claude's cwd-to-directory rule: every "/" becomes "-". Used as a FAST PATH
// only. It is an internal convention of another tool, so `sessionsForCwd` falls back to reading
// the cwd recorded inside the transcripts when the slug directory yields nothing. The shim
// sidesteps the same rule the same way, by globbing (shim/main.go:82-88).
func projectSlug(cwd string) string {
	return strings.ReplaceAll(cwd, "/", "-")
}

// transcriptCwd reads the `cwd` field out of a transcript. Not every line carries one (the
// opening line is often a "mode" record), so scan a bounded number of lines and give up rather
// than read a large file to its end. Returns "" when the file records no cwd.
func transcriptCwd(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	// Transcript lines carry whole tool results and routinely exceed bufio's 64KB default,
	// which would otherwise abort the scan with ErrTooLong and read as "no cwd here".
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	for i := 0; i < 40 && sc.Scan(); i++ {
		var rec struct {
			Cwd string `json:"cwd"`
		}
		if err := json.Unmarshal(sc.Bytes(), &rec); err != nil {
			continue
		}
		if rec.Cwd != "" {
			return rec.Cwd
		}
	}
	return ""
}

// sessionsFromDir collects the transcripts in one project directory, newest first. `wantCwd`
// filters on the recorded cwd when non-empty; the fast path passes "" because the directory
// name already established the match.
func sessionsFromDir(dir, wantCwd string) []Session {
	matches, _ := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	out := make([]Session, 0, len(matches))
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil || info.Size() == 0 {
			continue
		}
		cwd := ""
		if wantCwd != "" {
			cwd = transcriptCwd(path)
			if cwd != wantCwd {
				continue
			}
		}
		out = append(out, Session{
			ID:      strings.TrimSuffix(filepath.Base(path), ".jsonl"),
			Path:    path,
			Cwd:     cwd,
			ModTime: info.ModTime(),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModTime.After(out[j].ModTime) })
	return out
}

// SessionsForCwd returns the resumable sessions for a working directory, newest first.
// Empty (not an error) when the directory has never hosted a Claude Code session.
func SessionsForCwd(home, cwd string) []Session {
	projects := filepath.Join(home, ".claude", "projects")

	if found := sessionsFromDir(filepath.Join(projects, projectSlug(cwd)), ""); len(found) > 0 {
		return found
	}

	// Fallback: the slug rule did not land, so ask the transcripts themselves where they ran.
	dirs, _ := filepath.Glob(filepath.Join(projects, "*"))
	var all []Session
	for _, dir := range dirs {
		all = append(all, sessionsFromDir(dir, cwd)...)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].ModTime.After(all[j].ModTime) })
	return all
}

// SessionExists reports whether an explicitly-named session id has a transcript anywhere. Used
// by --session, where the caller supplies an id we should not silently discard if it is real but
// lives under a different project directory than the current cwd.
func SessionExists(home, id string) bool {
	matches, _ := filepath.Glob(filepath.Join(home, ".claude", "projects", "*", id+".jsonl"))
	return len(matches) > 0
}
