package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// DefaultPort is the gateway's prod default (GatewayProcess.swift:11). An installed app runs one
// instance, so this is right for everyone except a dev machine juggling several, which is what
// --port is for. See docs/plan-teleport.md section 3.2.
const DefaultPort = 4242

// ErrNotRunning means nothing is listening, i.e. Port42 is not up.
var ErrNotRunning = errors.New("port42 not running")

type callResponse struct {
	Content json.RawMessage `json:"content"`
	Error   string          `json:"error"`
}

// tokenForPort finds this CLI's credential for the instance listening on `port`.
//
// A token lives under an INSTANCE directory (`~/.port42/<instance>/tokens/port42-cli`) while the CLI
// targets a PORT, and a dev machine runs several instances at once — prod on 4242, dev builds on
// 4243/4245 — whose tokens deliberately do not interoperate (they are separated by their secrets, not
// by a path check). So the app writes the mapping down at enrolment and this reads it back. Guessing
// would mean presenting one instance's credential to another.
//
// **THERE IS NO SILENT ANONYMOUS FALLBACK** (GM, 2026-07-30). An earlier version returned "" on every
// failure so an unenrolled CLI would "keep working exactly as it does today" — reasoning inherited
// from a backward-compatibility concern that does not exist, because this CLI has never shipped. It
// was protecting nobody, and it degraded quietly to an anonymous caller, which is the exact class of
// bug this whole thread has been removing: a thing that reports success while doing something else.
//
// The app is what installs this CLI. So a gateway listening with no token for it is not a
// compatibility case, it is a broken enrolment — and it should be said out loud, now, rather than
// surface later as an unexplained 401 on a CLI you believed was enrolled.
//
// "Port42 is not running" is unaffected and stays a separate, friendlier error: with no gateway there
// is nothing to dial and `ErrNotRunning` already covers it.
func tokenForPort(port int) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot locate your home directory, so I cannot find this CLI's credential: %w", err)
	}
	root := filepath.Join(home, ".port42")
	dirs, err := filepath.Glob(filepath.Join(root, "*"))
	if err != nil {
		return "", fmt.Errorf("cannot read %s: %w", root, err)
	}

	for _, dir := range dirs {
		mapped, err := os.ReadFile(filepath.Join(dir, "gateway-port"))
		if err != nil || strings.TrimSpace(string(mapped)) != fmt.Sprint(port) {
			continue
		}
		tokenPath := filepath.Join(dir, "tokens", "port42-cli")
		tok, err := os.ReadFile(tokenPath)
		if err != nil {
			return "", fmt.Errorf("Port42 is on port %d but this CLI has no credential there.\n"+
				"Expected it at %s.\nIt is written when Port42 installs the CLI, so relaunching "+
				"Port42 should restore it.", port, tokenPath)
		}
		if t := strings.TrimSpace(string(tok)); t != "" {
			return t, nil
		}
		return "", fmt.Errorf("this CLI's credential at %s is empty. Relaunch Port42 to rewrite it.", tokenPath)
	}

	return "", fmt.Errorf("no Port42 instance claims port %d.\n"+
		"Each instance records its port in ~/.port42/<instance>/gateway-port when it installs the "+
		"CLI; none of them names %d. Relaunch the Port42 you are trying to reach.", port, port)
}

// Call invokes one bridge method over the gateway's local HTTP surface.
//
// It presents a CREDENTIAL when it has one (slice-02 half two). This comment used to read "No
// credential is involved: /call is loopback-only and authenticates nobody" — which was true, and was
// the reason any local process could name itself whatever it liked and inherit another tool's grants.
// The CLI is enrolled at install time, because installing it is a named act with the user present.
func Call(port int, method string, args any) (json.RawMessage, error) {
	body, err := json.Marshal(map[string]any{"method": method, "args": args})
	if err != nil {
		return nil, err
	}

	url := fmt.Sprintf("http://127.0.0.1:%d/call", port)
	client := &http.Client{Timeout: 30 * time.Second}
	httpReq, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	// No credential, no call. The CLI has no anonymous mode: it is installed by Port42 and enrolled
	// by that same act, so being unable to name itself means something is wrong and worth saying.
	tok, err := tokenForPort(port)
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+tok)
	resp, err := client.Do(httpReq)
	if err != nil {
		// Connection refused is the ordinary "app is not running" case, not a fault worth
		// showing a Go network error for.
		if strings.Contains(err.Error(), "connection refused") {
			return nil, ErrNotRunning
		}
		return nil, err
	}
	defer resp.Body.Close()

	var out callResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("gateway returned an unreadable response (HTTP %d)", resp.StatusCode)
	}
	if out.Error != "" {
		// The gateway answers 503 with this when the port is bound but the app is not attached
		// to it (gateway.go:823). Same user-facing meaning as a refused connection.
		if strings.Contains(out.Error, "no host available") || strings.Contains(out.Error, "host is offline") {
			return nil, ErrNotRunning
		}
		return nil, errors.New(out.Error)
	}
	return out.Content, nil
}

// CreatePort calls port.create and returns the new port's id and title.
func CreatePort(port int, options map[string]any) (id string, title string, err error) {
	content, err := Call(port, "port.create", options)
	if err != nil {
		return "", "", err
	}

	// `content` is the bridge value: normally the {id,title,token} object, but the gateway may
	// hand it back as a JSON string containing that object.
	raw := content
	var asString string
	if json.Unmarshal(content, &asString) == nil {
		raw = json.RawMessage(asString)
	}

	var result struct {
		ID    string `json:"id"`
		Title string `json:"title"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return "", "", fmt.Errorf("port.create returned an unexpected shape: %s", string(content))
	}
	if result.ID == "" {
		return "", "", fmt.Errorf("port.create returned no port id: %s", string(content))
	}
	return result.ID, result.Title, nil
}
