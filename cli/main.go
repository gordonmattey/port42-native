// port42 — the Port42 command line.
//
// One binary, verbs. The first verb is `teleport`: it takes the Claude Code session you are
// already in and re-launches it inside a Port42 terminal port, context intact, so the agent
// stops being a process in a pane and becomes something in a room you can share.
//
// See docs/plan-teleport.md. No third-party dependencies, matching gateway/ and shim/.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}

	switch os.Args[1] {
	case "teleport":
		os.Exit(runTeleport(os.Args[2:]))
	case "help", "--help", "-h":
		usage(os.Stdout)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "port42: unknown command %q\n\n", os.Args[1])
		usage(os.Stderr)
		os.Exit(2)
	}
}

func usage(w *os.File) {
	fmt.Fprint(w, `port42 — the Port42 command line

Usage:
  port42 teleport [flags]   Bring this terminal's Claude Code session into a Port42 port
  port42 help               Show this message

Teleport flags:
  --session <id>   Resume a specific session instead of the newest one for this directory
  --space <name>   Space to land in, by name or id. Omit it and you are asked, unless the
                   run is piped or scripted, in which case Port42's current space is used
  --port <n>       Gateway port. Omit it and the running Port42 is found for you; if more
                   than one is running you are asked which
  --list           List the sessions found for this directory and exit
  --dry-run        Print the port.create call that would be made and exit

Exit your Claude Code terminal first, then run port42 teleport from the same directory.
`)
}

func runTeleport(argv []string) int {
	fs := flag.NewFlagSet("teleport", flag.ExitOnError)
	sessionID := fs.String("session", "", "resume a specific session id")
	spaceID := fs.String("space", "", "space to create the port in")
	port := fs.Int("port", 0, "gateway port (default: find the running Port42)")
	list := fs.Bool("list", false, "list sessions for this directory and exit")
	dryRun := fs.Bool("dry-run", false, "print the call that would be made and exit")
	_ = fs.Parse(argv)

	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "port42: cannot determine the working directory: %v\n", err)
		return 1
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "port42: cannot determine the home directory: %v\n", err)
		return 1
	}

	if *list {
		return listSessions(home, cwd)
	}

	resume, err := resolveSession(home, cwd, *sessionID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "port42: %v\n", err)
		return 1
	}

	// A dry run that needs no space stays entirely local, so it works with Port42 shut down.
	offline := *dryRun && *spaceID == ""

	target := Instance{Port: *port}
	if !offline {
		if target, err = resolveInstance(*port); err != nil {
			reportError(err, *port)
			return 1
		}
	}

	chosenSpace, err := resolveSpace(target.Port, *spaceID, *dryRun)
	if err != nil {
		reportError(err, target.Port)
		return 1
	}

	options := buildOptions(cwd, resume, chosenSpace)

	if *dryRun {
		encoded, _ := json.MarshalIndent(map[string]any{
			"method": "port.create",
			"args":   options,
		}, "", "  ")
		fmt.Println(string(encoded))
		return 0
	}

	id, title, err := CreatePort(target.Port, options)
	if err != nil {
		reportError(err, target.Port)
		return 1
	}

	where := "Port42"
	if chosenSpace.Name != "" {
		where = "#" + chosenSpace.Name
	}
	if target.Name != "" {
		where += " on " + target.Name
	}
	if resume == "" {
		fmt.Printf("Opened a new Claude Code port in %s (%s).\n", where, title)
		fmt.Printf("No previous session for this directory, so this one starts fresh.\n")
	} else {
		fmt.Printf("Teleported session %s into %s (%s).\n", short(resume), where, title)
		fmt.Printf("Your context came with it. If the original terminal is still open, close it.\n")
	}
	fmt.Printf("Port id: %s\n", id)
	return 0
}

// resolveSession picks the session to resume. Empty return means "none found, start fresh",
// which is a normal outcome rather than an error: teleport doubles as "get me into Port42 from
// here" in a directory that has never hosted a session (docs/plan-teleport.md section 4).
func resolveSession(home, cwd, explicit string) (string, error) {
	if explicit != "" {
		if !SessionExists(home, explicit) {
			return "", fmt.Errorf("no transcript found for session %s", explicit)
		}
		return explicit, nil
	}
	sessions := SessionsForCwd(home, cwd)
	if len(sessions) == 0 {
		return "", nil
	}
	return sessions[0].ID, nil
}

func listSessions(home, cwd string) int {
	sessions := SessionsForCwd(home, cwd)
	if len(sessions) == 0 {
		fmt.Printf("No Claude Code sessions found for %s\n", cwd)
		return 0
	}
	fmt.Printf("Sessions for %s, newest first:\n\n", cwd)
	for i, s := range sessions {
		marker := "  "
		if i == 0 {
			marker = "* "
		}
		fmt.Printf("%s%s  %s\n", marker, s.ID, s.ModTime.Format("2006-01-02 15:04"))
	}
	fmt.Printf("\n* is the one teleport would resume. Override with --session <id>.\n")
	return 0
}

// buildOptions assembles the port.create call.
//
// --fork-session is load-bearing. Inside a Port42 terminal the shim injects its own
// `--session-id <derived>` ahead of these args (shim/main.go:120-128), and claude REJECTS
// --session-id alongside --resume unless --fork-session is also present. Verified against the
// real CLI. Forking also means the original transcript is never written by two clients, so
// leaving the outside terminal open is untidy rather than dangerous.
func buildOptions(cwd, resume string, space Space) map[string]any {
	options := map[string]any{
		"type":    "terminal",
		"command": "claude",
		"cwd":     cwd,
		"title":   teleportTitle(cwd),
	}
	if resume != "" {
		options["args"] = []string{"--resume", resume, "--fork-session"}
	}
	// Omitted rather than empty when unresolved, so the app applies its own current-space
	// default (BridgeMethods.swift:168) instead of being handed a blank id.
	if space.ID != "" {
		options["space_id"] = space.ID
	}
	return options
}

// resolveSpace decides which space the port lands in.
//
//   - --space given: match it, so a wrong name fails loudly with the list rather than silently
//     landing the agent in the wrong room.
//   - interactive: ask, defaulting to the space Port42 is showing.
//   - piped, scripted, or --dry-run: resolve nothing and let the app pick the current space.
//     A prompt nobody can answer would hang, and --dry-run must not require a running gateway.
func resolveSpace(port int, want string, dryRun bool) (Space, error) {
	if want == "" && (dryRun || !isInteractive()) {
		return Space{}, nil
	}

	spaces, err := ListSpaces(port)
	if err != nil {
		return Space{}, err
	}
	if want != "" {
		return MatchSpace(spaces, want)
	}

	current, err := CurrentSpace(port)
	if err != nil {
		return Space{}, err
	}
	return ChooseSpace(os.Stderr, os.Stdin, spaces, current)
}

// resolveInstance finds the Port42 to teleport into. An explicit --port is taken at its word so
// the flag still works against an instance on a port discovery does not sweep.
func resolveInstance(explicit int) (Instance, error) {
	if explicit != 0 {
		return Instance{Port: explicit}, nil
	}
	return ChooseInstance(os.Stderr, os.Stdin, DiscoverInstances(), isInteractive())
}

func reportError(err error, port int) {
	if err == ErrNotRunning {
		if port == 0 {
			fmt.Fprintln(os.Stderr, "port42: no running Port42 found.")
		} else {
			fmt.Fprintf(os.Stderr, "port42: Port42 is not running (nothing answering on port %d).\n", port)
		}
		fmt.Fprintln(os.Stderr, "        Start Port42 and run this again.")
		return
	}
	fmt.Fprintf(os.Stderr, "port42: %v\n", err)
}

// teleportTitle names the port after the branch, falling back to the directory. Both are more
// use on a tile than the session's UUID.
func teleportTitle(cwd string) string {
	cmd := exec.Command("git", "rev-parse", "--abbrev-ref", "HEAD")
	cmd.Dir = cwd
	if out, err := cmd.Output(); err == nil {
		if branch := strings.TrimSpace(string(out)); branch != "" {
			return "teleport: " + branch
		}
	}
	return "teleport: " + filepath.Base(cwd)
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
