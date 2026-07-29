package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

// Space is one Port42 space the port can be created in.
type Space struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// decodeContent unwraps a bridge value that may arrive as a JSON document or as a JSON string
// containing one.
func decodeContent(content json.RawMessage, into any) error {
	raw := content
	var asString string
	if json.Unmarshal(content, &asString) == nil {
		raw = json.RawMessage(asString)
	}
	return json.Unmarshal(raw, into)
}

// ListSpaces returns the spaces this instance knows about.
func ListSpaces(port int) ([]Space, error) {
	content, err := Call(port, "space.list", map[string]any{})
	if err != nil {
		return nil, err
	}
	var spaces []Space
	if err := decodeContent(content, &spaces); err != nil {
		return nil, fmt.Errorf("space.list returned an unexpected shape: %s", string(content))
	}
	return spaces, nil
}

// CurrentSpace returns the space the app is currently showing.
func CurrentSpace(port int) (Space, error) {
	content, err := Call(port, "space.current", map[string]any{})
	if err != nil {
		return Space{}, err
	}
	var space Space
	if err := decodeContent(content, &space); err != nil {
		return Space{}, fmt.Errorf("space.current returned an unexpected shape: %s", string(content))
	}
	return space, nil
}

// MatchSpace resolves a user-supplied --space value against the known spaces. An exact id wins;
// otherwise the name is matched case-insensitively. Ambiguity is an error rather than a guess,
// because landing an agent in the wrong room is not something to be casual about.
func MatchSpace(spaces []Space, want string) (Space, error) {
	for _, s := range spaces {
		if s.ID == want {
			return s, nil
		}
	}
	var hits []Space
	for _, s := range spaces {
		if strings.EqualFold(s.Name, want) {
			hits = append(hits, s)
		}
	}
	switch len(hits) {
	case 1:
		return hits[0], nil
	case 0:
		return Space{}, fmt.Errorf("no space called %q.\n%s", want, formatSpaces(spaces))
	default:
		return Space{}, fmt.Errorf("more than one space is called %q, so pass its id instead.\n%s", want, formatSpaces(spaces))
	}
}

func formatSpaces(spaces []Space) string {
	if len(spaces) == 0 {
		return "This instance has no spaces."
	}
	var b strings.Builder
	b.WriteString("Available spaces:\n")
	for _, s := range spaces {
		fmt.Fprintf(&b, "  %-20s %s\n", s.Name, s.ID)
	}
	return b.String()
}

// isInteractive reports whether we can put a prompt in front of a human. Piped or scripted runs
// must never block waiting on an answer nobody is there to give.
//
// This asks the kernel for the terminal attributes rather than testing os.ModeCharDevice, which
// is the usual shorthand and is wrong here: /dev/null is itself a character device, so the
// common `cmd < /dev/null` idiom would be mistaken for a human at a keyboard.
func isInteractive() bool {
	var termios syscall.Termios
	_, _, errno := syscall.Syscall6(
		syscall.SYS_IOCTL,
		os.Stdin.Fd(),
		syscall.TIOCGETA,
		uintptr(unsafe.Pointer(&termios)),
		0, 0, 0,
	)
	return errno == 0
}

// ChooseSpace prompts for a space, defaulting to the current one on an empty answer. The menu
// goes to stderr so stdout stays clean for anything reading this command's output.
func ChooseSpace(w io.Writer, r io.Reader, spaces []Space, current Space) (Space, error) {
	if len(spaces) == 0 {
		return current, nil
	}
	if len(spaces) == 1 {
		return spaces[0], nil
	}

	fmt.Fprintln(w, "Which space should the session land in?")
	fmt.Fprintln(w)
	defaultIndex := 0
	for i, s := range spaces {
		marker := " "
		if s.ID == current.ID {
			marker = "*"
			defaultIndex = i
		}
		fmt.Fprintf(w, " %s %d) %s\n", marker, i+1, s.Name)
	}
	fmt.Fprintf(w, "\n* is the space Port42 is showing now. Enter to take it, or pick a number: ")

	line, err := bufio.NewReader(r).ReadString('\n')
	if err != nil && strings.TrimSpace(line) == "" {
		// No answer available (EOF on a closed stdin). Take the default rather than fail.
		fmt.Fprintln(w)
		return spaces[defaultIndex], nil
	}
	answer := strings.TrimSpace(line)
	if answer == "" {
		return spaces[defaultIndex], nil
	}

	n, err := strconv.Atoi(answer)
	if err != nil || n < 1 || n > len(spaces) {
		return Space{}, fmt.Errorf("%q is not one of the listed choices", answer)
	}
	return spaces[n-1], nil
}
