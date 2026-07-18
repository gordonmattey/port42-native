package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// setupTestServerWithCall mounts both /ws and /call so HandleHTTPCall can be exercised.
func setupTestServerWithCall(gw *Gateway) (*httptest.Server, string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", gw.HandleWebSocket)
	mux.HandleFunc("/call", gw.HandleHTTPCall)
	srv := httptest.NewServer(mux)
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	return srv, wsURL
}

// mockHost connects as the global host, then echoes a response for every "call" it receives,
// recording the SenderID each forwarded call arrived with. It answers with the matching
// CallID + TargetID so the HTTP handler's httpCallbacks routing resolves.
type mockHost struct {
	mu        sync.Mutex
	senderIDs []string
}

func (m *mockHost) observed() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]string, len(m.senderIDs))
	copy(out, m.senderIDs)
	return out
}

func (m *mockHost) run(t *testing.T, ctx context.Context, conn *websocket.Conn) {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return // context cancelled / conn closed at test end
		}
		var env Envelope
		if err := json.Unmarshal(data, &env); err != nil {
			continue
		}
		if env.Type != "call" {
			continue
		}
		m.mu.Lock()
		m.senderIDs = append(m.senderIDs, env.SenderID)
		m.mu.Unlock()

		resp := Envelope{
			Type:     "response",
			CallID:   env.CallID,
			TargetID: env.SenderID,
			Payload:  json.RawMessage(`{"ok":true}`),
		}
		out, _ := json.Marshal(resp)
		_ = conn.Write(ctx, websocket.MessageText, out)
	}
}

// startMockHost dials, identifies as the host (populating globalHostID), consumes the welcome,
// and starts the echo loop.
func startMockHost(t *testing.T, ctx context.Context, wsURL string) (*mockHost, *websocket.Conn) {
	t.Helper()
	conn, first := dialAndRead(t, ctx, wsURL) // no_auth hint (no verifier)
	if first.Type != "no_auth" {
		t.Fatalf("expected no_auth, got %s", first.Type)
	}
	sendEnvelope(t, ctx, conn, Envelope{Type: "identify", SenderID: "host-peer", SenderName: "Host", IsHost: true})
	welcome := readEnvelope(t, ctx, conn)
	if welcome.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", welcome.Type)
	}
	mh := &mockHost{}
	go mh.run(t, ctx, conn)
	return mh, conn
}

func httpCall(t *testing.T, srvURL, method string) map[string]any {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"method": method, "args": map[string]any{}})
	resp, err := http.Post(srvURL+"/call", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("http post failed: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("decode response failed: %v (body=%s)", err, raw)
	}
	return out
}

// TestHTTPCallStableLocalSenderID asserts a local /call reaches the host with the stable
// principal id "local-http", not a per-call synthetic id.
func TestHTTPCallStableLocalSenderID(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServerWithCall(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	mh, hostConn := startMockHost(t, ctx, wsURL)
	defer hostConn.CloseNow()

	out := httpCall(t, srv.URL, "user.get")
	if ok, _ := out["ok"].(bool); !ok {
		t.Fatalf("expected {ok:true} echoed back, got %v", out)
	}

	observed := mh.observed()
	if len(observed) != 1 {
		t.Fatalf("expected host to receive 1 call, got %d (%v)", len(observed), observed)
	}
	if observed[0] != "local-http" {
		t.Fatalf("expected SenderID local-http, got %q", observed[0])
	}
}

// TestHTTPCallConcurrentRoutingByCallID asserts two overlapping local calls (same SenderID,
// distinct CallIDs) each get their own response — proving routing is keyed on CallID, not SenderID.
func TestHTTPCallConcurrentRoutingByCallID(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServerWithCall(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	mh, hostConn := startMockHost(t, ctx, wsURL)
	defer hostConn.CloseNow()

	const n = 2
	var wg sync.WaitGroup
	oks := make([]bool, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			out := httpCall(t, srv.URL, "user.get")
			oks[idx], _ = out["ok"].(bool)
		}(i)
	}
	wg.Wait()

	for i, ok := range oks {
		if !ok {
			t.Fatalf("call %d did not receive its response", i)
		}
	}
	observed := mh.observed()
	if len(observed) != n {
		t.Fatalf("expected host to receive %d calls, got %d", n, len(observed))
	}
	for _, s := range observed {
		if s != "local-http" {
			t.Fatalf("expected every SenderID to be local-http, got %q", s)
		}
	}
}
