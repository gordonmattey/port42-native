package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
)

// `port42 skills install|uninstall|status` (nautilus Phase 5.3). In a Port42 terminal the skills load
// for the session on their own; this is for sessions Port42 did not start. It is the person's choice,
// never done at launch: it writes into ~/.claude/skills and ~/.codex/skills.
//
// A copied skill carries a marker file, so install replaces only its own earlier copies and
// uninstall removes only those, never a skill of the person's that happens to share a name.
const skillMarker = ".port42-installed"

// skillTargets are the skill folders of the CLIs Port42 knows.
func skillTargets(home string) []string {
	return []string{filepath.Join(home, ".claude", "skills"), filepath.Join(home, ".codex", "skills")}
}

// skillsSource finds the running app's skills: the terminal says where (PORT42_SKILLS_DIR), or they
// sit beside this command in the app bundle.
func skillsSource(env func(string) string) (string, error) {
	if d := env("PORT42_SKILLS_DIR"); d != "" {
		return filepath.Join(d, "skills"), nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	d := filepath.Join(filepath.Dir(exe), "..", "Resources", "Port42_Port42Lib.bundle", "port42-skills", "skills")
	if st, err := os.Stat(d); err != nil || !st.IsDir() {
		return "", fmt.Errorf("cannot find Port42's skills beside %s; run this from a Port42 terminal", exe)
	}
	return filepath.Clean(d), nil
}

func skillNames(src string) ([]string, error) {
	entries, err := os.ReadDir(src)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() && e.Name()[0] != '.' {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// installSkills copies every skill into each target. It refuses to replace a folder it did not put
// there, and reports what it did.
func installSkills(src string, targets []string, out io.Writer) error {
	names, err := skillNames(src)
	if err != nil {
		return err
	}
	for _, t := range targets {
		if err := os.MkdirAll(t, 0o755); err != nil {
			return err
		}
		for _, n := range names {
			dst := filepath.Join(t, n)
			if _, err := os.Stat(dst); err == nil {
				if _, err := os.Stat(filepath.Join(dst, skillMarker)); err != nil {
					fmt.Fprintf(out, "skipped %s: a skill of yours already has that name\n", dst)
					continue
				}
				if err := os.RemoveAll(dst); err != nil {
					return err
				}
			}
			if err := copyTree(filepath.Join(src, n), dst); err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(dst, skillMarker), []byte("installed by port42 skills install\n"), 0o644); err != nil {
				return err
			}
			fmt.Fprintf(out, "installed %s\n", dst)
		}
	}
	return nil
}

// uninstallSkills removes only the skills install put there.
func uninstallSkills(targets []string, out io.Writer) error {
	for _, t := range targets {
		entries, _ := os.ReadDir(t)
		for _, e := range entries {
			dst := filepath.Join(t, e.Name())
			if _, err := os.Stat(filepath.Join(dst, skillMarker)); err == nil {
				if err := os.RemoveAll(dst); err != nil {
					return err
				}
				fmt.Fprintf(out, "removed %s\n", dst)
			}
		}
	}
	return nil
}

func copyTree(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
}

func runSkills(args []string, out, errOut io.Writer) int {
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(errOut, "port42 skills: %v\n", err)
		return 1
	}
	verb := "status"
	if len(args) > 0 {
		verb = args[0]
	}
	switch verb {
	case "install":
		src, err := skillsSource(os.Getenv)
		if err == nil {
			err = installSkills(src, skillTargets(home), out)
		}
		if err != nil {
			fmt.Fprintf(errOut, "port42 skills install: %v\n", err)
			return 1
		}
		return 0
	case "uninstall":
		if err := uninstallSkills(skillTargets(home), out); err != nil {
			fmt.Fprintf(errOut, "port42 skills uninstall: %v\n", err)
			return 1
		}
		return 0
	case "status":
		for _, t := range skillTargets(home) {
			entries, _ := os.ReadDir(t)
			n := 0
			for _, e := range entries {
				if _, err := os.Stat(filepath.Join(t, e.Name(), skillMarker)); err == nil {
					n++
				}
			}
			fmt.Fprintf(out, "%s: %d Port42 skill(s) installed\n", t, n)
		}
		fmt.Fprintln(out, "In a Port42 terminal the skills load on their own; install is for sessions Port42 did not start.")
		return 0
	default:
		fmt.Fprintf(errOut, "port42 skills: unknown %q (install, uninstall, status)\n", verb)
		return 2
	}
}
