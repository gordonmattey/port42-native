package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// A web page must not reach a loopback gateway, directly or by DNS rebinding (GW-05).
func TestLoopbackOnlyRefusesBrowsersAndForeignHosts(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	h := loopbackOnly(ok)
	cases := []struct {
		host, origin string
		want         int
	}{
		{"127.0.0.1:4242", "", http.StatusOK}, // app, CLI, Node peer
		{"localhost:4242", "", http.StatusOK},
		{"[::1]:4242", "", http.StatusOK},
		{"127.0.0.1:4242", "https://evil.example", http.StatusForbidden},
		{"127.0.0.1:4242", "null", http.StatusForbidden},         // sandboxed iframe, file://
		{"evil.example:4242", "", http.StatusMisdirectedRequest}, // rebinding
		{"evil.example", "", http.StatusMisdirectedRequest},
	}
	for _, c := range cases {
		r := httptest.NewRequest(http.MethodPost, "/call", nil)
		r.Host = c.host
		if c.origin != "" {
			r.Header.Set("Origin", c.origin)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != c.want {
			t.Errorf("host=%q origin=%q: got %d, want %d", c.host, c.origin, w.Code, c.want)
		}
	}
}

// Without the wildcard, a browser on another origin cannot open the WebSocket even on a network
// listener, while a client that sends no Origin still can.
func TestWebSocketRefusesCrossOrigin(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	hdr := http.Header{}
	hdr.Set("Origin", "https://evil.example")
	if c, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPHeader: hdr}); err == nil {
		c.CloseNow()
		t.Fatal("a cross-origin browser handshake was accepted")
	}

	c, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("a client with no Origin was refused: %v", err)
	}
	c.CloseNow()
}

// The app's loopback listener is served behind the guard; a network listener is not.
func TestTheLoopbackListenerIsGuarded(t *testing.T) {
	for _, c := range []struct {
		addr    string
		guarded bool
	}{{"127.0.0.1:4242", true}, {"localhost:4242", true}, {"[::1]:4242", true}, {":4242", false}, {"0.0.0.0:4242", false}} {
		r := httptest.NewRequest(http.MethodGet, "/health", nil)
		r.Host = "127.0.0.1:4242"
		r.Header.Set("Origin", "https://evil.example")
		w := httptest.NewRecorder()
		serverHandler(c.addr, NewGateway()).ServeHTTP(w, r)
		if refused := w.Code == http.StatusForbidden; refused != c.guarded {
			t.Errorf("%s: status %d, guarded=%v", c.addr, w.Code, c.guarded)
		}
	}
}

// A gateway launched by hand with no -addr listens on loopback only (GW-11), where the loopback guard
// applies.
func TestTheDefaultListenAddressIsLoopback(t *testing.T) {
	if !isLoopbackAddr(defaultAddr) {
		t.Fatalf("the default listen address %q is reachable from the network", defaultAddr)
	}
}
