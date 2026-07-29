package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
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

// Call invokes one bridge method over the gateway's local HTTP surface. No credential is
// involved: /call is loopback-only and authenticates nobody (gateway/gateway.go:802-856).
func Call(port int, method string, args any) (json.RawMessage, error) {
	body, err := json.Marshal(map[string]any{"method": method, "args": args})
	if err != nil {
		return nil, err
	}

	url := fmt.Sprintf("http://127.0.0.1:%d/call", port)
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
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
