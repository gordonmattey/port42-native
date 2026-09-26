package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// `port42 <method> [args]` calls one bridge method, so an agent reaches Port42 with one short
// command instead of a curl it has to quote (GM, 2026-09-26: tools by the CLI, not MCP). The CLI
// knows no methods itself: the registry is the gateway's, and `port42 help api` prints it, so a
// method added to the registry is callable here the moment the app has it.
//
// Arguments, in the style of httpie so HTML never passes through shell quoting or jq:
//
//	key=value    a string
//	key:=json    a raw JSON value (a number, true, an object)
//	key=@path    the file's contents as a string (@- is stdin)
//	'{...}'      one JSON object holding every argument
func isMethod(verb string) bool {
	return strings.Contains(verb, ".") || verb == "whoami"
}

// parseMethodArgs turns the words after the method into its args object.
func parseMethodArgs(words []string, stdin io.Reader) (map[string]any, error) {
	args := map[string]any{}
	for _, w := range words {
		if strings.HasPrefix(strings.TrimSpace(w), "{") {
			var obj map[string]any
			if err := json.Unmarshal([]byte(w), &obj); err != nil {
				return nil, fmt.Errorf("not a JSON object: %v", err)
			}
			for k, v := range obj {
				args[k] = v
			}
			continue
		}
		if i := strings.Index(w, ":="); i > 0 && (strings.Index(w, "=") == i+1) {
			var v any
			if err := json.Unmarshal([]byte(w[i+2:]), &v); err != nil {
				return nil, fmt.Errorf("%s: not JSON: %v", w[:i], err)
			}
			args[w[:i]] = v
			continue
		}
		i := strings.Index(w, "=")
		if i <= 0 {
			return nil, fmt.Errorf("%q is not key=value, key:=json, key=@file or a JSON object", w)
		}
		key, val := w[:i], w[i+1:]
		if strings.HasPrefix(val, "@") {
			var data []byte
			var err error
			if val == "@-" {
				data, err = io.ReadAll(stdin)
			} else {
				data, err = os.ReadFile(val[1:])
			}
			if err != nil {
				return nil, fmt.Errorf("%s: %v", key, err)
			}
			val = string(data)
		}
		args[key] = val
	}
	return args, nil
}

// callerCredential says who is calling and where. A session Port42 started carries its own
// identity (PORT42_TOKEN_FILE) and its own instance's port (PORT42_GATEWAY_PORT), and calls as
// itself: presenting the CLI's install credential instead would be borrowing another client's
// identity. Anywhere else, the CLI calls as itself on the instance that claims the port.
func callerCredential(explicitPort int, env func(string) string) (port int, token string, err error) {
	port = explicitPort
	if port == 0 {
		if p, e := strconv.Atoi(env("PORT42_GATEWAY_PORT")); e == nil {
			port = p
		} else {
			port = DefaultPort
		}
	}
	if file := env("PORT42_TOKEN_FILE"); file != "" {
		tok, e := os.ReadFile(file)
		if e != nil {
			return 0, "", fmt.Errorf("cannot read your token at %s (PORT42_TOKEN_FILE): %v", file, e)
		}
		if t := strings.TrimSpace(string(tok)); t != "" {
			return port, t, nil
		}
		return 0, "", fmt.Errorf("your token at %s (PORT42_TOKEN_FILE) is empty", file)
	}
	tok, err := tokenForPort(port)
	return port, tok, err
}

// bridgeError is the {error, code, ...} object a refused call answers with, inside `content`.
func bridgeError(content json.RawMessage) (map[string]any, bool) {
	var obj map[string]any
	if json.Unmarshal(content, &obj) != nil {
		return nil, false
	}
	_, hasErr := obj["error"]
	_, hasCode := obj["code"]
	return obj, hasErr && hasCode
}

// unwrap returns the content with a JSON-string layer removed: the gateway may hand a result back
// as a string holding JSON.
func unwrap(content json.RawMessage) json.RawMessage {
	var s string
	if json.Unmarshal(content, &s) == nil {
		if json.Valid([]byte(s)) {
			return json.RawMessage(s)
		}
		b, _ := json.Marshal(s)
		return b
	}
	return content
}

func runMethod(method string, words []string, stdout, stderr io.Writer, stdin io.Reader) int {
	explicitPort := 0
	var rest []string
	for i := 0; i < len(words); i++ {
		if words[i] == "--port" && i+1 < len(words) {
			p, err := strconv.Atoi(words[i+1])
			if err != nil {
				fmt.Fprintf(stderr, "port42: --port %q is not a number\n", words[i+1])
				return 2
			}
			explicitPort = p
			i++
			continue
		}
		rest = append(rest, words[i])
	}
	args, err := parseMethodArgs(rest, stdin)
	if err != nil {
		fmt.Fprintf(stderr, "port42 %s: %v\n", method, err)
		return 2
	}
	port, token, err := callerCredential(explicitPort, os.Getenv)
	if err != nil {
		fmt.Fprintf(stderr, "port42: %v\n", err)
		return 1
	}
	content, err := callWithToken(port, token, method, args)
	if errors.Is(err, ErrNotRunning) {
		fmt.Fprintf(stderr, "port42: nothing is answering on port %d. Is Port42 running?\n", port)
		return 1
	}
	if err != nil {
		fmt.Fprintf(stderr, "port42 %s: %v\n", method, err)
		return 1
	}
	content = unwrap(content)
	if obj, isErr := bridgeError(content); isErr {
		// The whole object, so `code` and `current` (a stale write's retry value) reach the caller.
		b, _ := json.Marshal(obj)
		fmt.Fprintln(stderr, string(b))
		return 1
	}
	var s string
	if json.Unmarshal(content, &s) == nil {
		fmt.Fprintln(stdout, s) // text, such as help, prints as text
	} else {
		fmt.Fprintln(stdout, string(content))
	}
	return 0
}

// callWithToken posts one call with the given credential and returns its content.
func callWithToken(port int, token, method string, args any) (json.RawMessage, error) {
	body, err := json.Marshal(map[string]any{"method": method, "args": args})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/call", port), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := (&http.Client{Timeout: 120 * time.Second}).Do(req)
	if err != nil {
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
		if strings.Contains(out.Error, "no host available") || strings.Contains(out.Error, "host is offline") {
			return nil, ErrNotRunning
		}
		return nil, errors.New(out.Error)
	}
	return out.Content, nil
}
