package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// port42 skills install copies the app's skills into the CLIs' skill folders, replaces only its own
// earlier copies, and uninstall removes only those (nautilus Phase 5.3).
func TestSkillsInstallOwnsOnlyItsOwn(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "app", "skills")
	for _, n := range []string{"port42", "port42-ports"} {
		os.MkdirAll(filepath.Join(src, n), 0o755)
		os.WriteFile(filepath.Join(src, n, "SKILL.md"), []byte("---\nname: "+n+"\n---\n"), 0o644)
	}
	target := filepath.Join(root, "home", ".claude", "skills")
	os.MkdirAll(filepath.Join(target, "port42-ports"), 0o755) // the person's own skill of that name
	os.WriteFile(filepath.Join(target, "port42-ports", "SKILL.md"), []byte("mine"), 0o644)

	var out bytes.Buffer
	if err := installSkills(src, []string{target}, &out); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(target, "port42", "SKILL.md")); !strings.Contains(string(b), "name: port42") {
		t.Fatalf("port42 not installed: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(target, "port42-ports", "SKILL.md")); string(b) != "mine" {
		t.Fatalf("the person's own skill was replaced: %q", b)
	}
	// A second install replaces its own copy.
	os.WriteFile(filepath.Join(src, "port42", "SKILL.md"), []byte("---\nname: port42\n---\nv2"), 0o644)
	installSkills(src, []string{target}, &out)
	if b, _ := os.ReadFile(filepath.Join(target, "port42", "SKILL.md")); !strings.Contains(string(b), "v2") {
		t.Fatalf("a second install did not update its own copy: %q", b)
	}
	uninstallSkills([]string{target}, &out)
	if _, err := os.Stat(filepath.Join(target, "port42")); err == nil {
		t.Fatal("uninstall left its skill")
	}
	if _, err := os.Stat(filepath.Join(target, "port42-ports", "SKILL.md")); err != nil {
		t.Fatal("uninstall removed the person's own skill")
	}
}

func TestSkillsSourceFromTheTerminal(t *testing.T) {
	d, err := skillsSource(func(k string) string {
		if k == "PORT42_SKILLS_DIR" {
			return "/app/port42-skills"
		}
		return ""
	})
	if err != nil || d != "/app/port42-skills/skills" {
		t.Fatalf("got %q %v", d, err)
	}
}
