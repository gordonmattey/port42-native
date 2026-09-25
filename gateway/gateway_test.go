package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

func setupTestServer(gw *Gateway) (*httptest.Server, string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", gw.HandleWebSocket)
	srv := httptest.NewServer(mux)
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	return srv, wsURL
}

func dialAndRead(t *testing.T, ctx context.Context, wsURL string) (*websocket.Conn, Envelope) {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	return conn, env
}

func sendEnvelope(t *testing.T, ctx context.Context, conn *websocket.Conn, env Envelope) {
	t.Helper()
	data, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write failed: %v", err)
	}
}

func readEnvelope(t *testing.T, ctx context.Context, conn *websocket.Conn) Envelope {
	t.Helper()
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	return env
}

// identified dials the gateway and identifies, returning the connection after its welcome.
func identified(t *testing.T, ctx context.Context, wsURL, id string, host bool) *websocket.Conn {
	t.Helper()
	conn, _ := dialAndRead(t, ctx, wsURL)
	sendEnvelope(t, ctx, conn, Envelope{Type: "identify", SenderID: id, SenderName: id, IsHost: host})
	if env := readEnvelope(t, ctx, conn); env.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", env.Type)
	}
	return conn
}

// --- Tests ---

func TestNoAuthChallenge(t *testing.T) {
	// Without an auth verifier, a no_auth hint is sent instead of a challenge.
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, noAuth := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()

	if noAuth.Type != "no_auth" {
		t.Fatalf("expected no_auth, got %s", noAuth.Type)
	}

	// Send identify immediately
	sendEnvelope(t, ctx, conn, Envelope{
		Type:       "identify",
		SenderID:   "peer-1",
		SenderName: "Test",
	})

	// Should get welcome back
	env := readEnvelope(t, ctx, conn)
	if env.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", env.Type)
	}
	if env.SenderID != "peer-1" {
		t.Fatalf("expected sender_id peer-1, got %s", env.SenderID)
	}
}

func TestPeerIDTooLong(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _ := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()

	longID := strings.Repeat("x", maxPeerIDLen+1)
	sendEnvelope(t, ctx, conn, Envelope{Type: "identify", SenderID: longID, SenderName: "A"})

	// Connection should be closed
	_, _, err := conn.Read(ctx)
	if err == nil {
		t.Fatal("expected connection to be closed for oversized peer ID")
	}
}

func TestRateLimiting(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn := identified(t, ctx, wsURL, "peer-flood", false)
	defer conn.CloseNow()

	for i := 0; i < rateLimitPerSec+10; i++ {
		sendEnvelope(t, ctx, conn, Envelope{Type: "call", Method: "x", CallID: fmt.Sprintf("c-%d", i)})
	}
	for i := 0; i < rateLimitPerSec+10; i++ {
		env := readEnvelope(t, ctx, conn)
		if env.Type == "error" && env.Error == "rate limit exceeded" {
			return
		}
	}
	t.Fatal("expected rate limit error after flooding calls")
}

// A WebSocket caller's call reaches the host, and the host's response comes back to that caller. No
// channel is joined at any point: the door needs none.
func TestRPCRouting(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	connHost := identified(t, ctx, wsURL, "host-peer", true)
	defer connHost.CloseNow()
	connCLI := identified(t, ctx, wsURL, "cli-peer", false)
	defer connCLI.CloseNow()

	callID := "call-123"
	sendEnvelope(t, ctx, connCLI, Envelope{Type: "call", Method: "terminal.exec", CallID: callID})

	hostCall := readEnvelope(t, ctx, connHost)
	if hostCall.Type != "call" || hostCall.CallID != callID || hostCall.SenderID != "cli-peer" {
		t.Fatalf("host got %+v", hostCall)
	}
	if !hostCall.Streamable {
		t.Fatal("a WS caller's call must reach the host marked streamable")
	}

	sendEnvelope(t, ctx, connHost, Envelope{
		Type: "response", CallID: callID, TargetID: "cli-peer",
		Payload: json.RawMessage(`{"content":"success"}`),
	})
	cliResp := readEnvelope(t, ctx, connCLI)
	if cliResp.Type != "response" || cliResp.CallID != callID {
		t.Fatalf("caller got %+v", cliResp)
	}
	var payload map[string]string
	json.Unmarshal(cliResp.Payload, &payload)
	if payload["content"] != "success" {
		t.Fatalf("expected success payload, got %v", payload)
	}
}

// With no host connected, a call is refused with a code rather than left hanging.
func TestCallWithNoHostIsRefused(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn := identified(t, ctx, wsURL, "lonely", false)
	defer conn.CloseNow()
	sendEnvelope(t, ctx, conn, Envelope{Type: "call", Method: "x", CallID: "c-1"})
	env := readEnvelope(t, ctx, conn)
	if env.Type != "error" || env.Code != CodeNoHost || env.CallID != "c-1" {
		t.Fatalf("expected no_host on c-1, got %+v", env)
	}
}

// THE HUB IS GONE (nautilus Phase 0 step 3). Every messaging envelope type is refused as unknown,
// with a code, so a stale client learns what happened instead of going quiet.
func TestHubEnvelopesRefused(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn := identified(t, ctx, wsURL, "old-client", false)
	defer conn.CloseNow()

	for _, typ := range []string{"join", "leave", "message", "typing", "read", "create_token", "ack"} {
		raw := fmt.Sprintf(`{"type":%q,"channel_id":"chan-1","sender_id":"old-client"}`, typ)
		if err := conn.Write(ctx, websocket.MessageText, []byte(raw)); err != nil {
			t.Fatalf("write %s: %v", typ, err)
		}
		env := readEnvelope(t, ctx, conn)
		if env.Type != "error" || env.Code != CodeUnknownMethod {
			t.Fatalf("%s: expected unknown_method, got %+v", typ, env)
		}
	}
}

// The HTTP door works with no channel state anywhere: a call reaches the host and its response
// becomes the HTTP body.
func TestHTTPCallNeedsNoChannelState(t *testing.T) {
	gw := NewGateway()
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", gw.HandleWebSocket)
	mux.HandleFunc("/call", gw.HandleHTTPCall)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	host := identified(t, ctx, wsURL, "host", true)
	defer host.CloseNow()
	go func() {
		call := readEnvelope(t, ctx, host)
		sendEnvelope(t, ctx, host, Envelope{Type: "response", CallID: call.CallID, TargetID: call.SenderID,
			Payload: json.RawMessage(`{"content":"pong"}`)})
	}()

	resp, err := http.Post(srv.URL+"/call", "application/json", strings.NewReader(`{"method":"ping"}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	if body["content"] != "pong" {
		t.Fatalf("expected pong, got %v (status %d)", body, resp.StatusCode)
	}
}
