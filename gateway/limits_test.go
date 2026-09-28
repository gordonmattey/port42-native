package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The gateway's listener has a header timeout, so a slow client cannot hold a connection (GW-12).
func TestTheGatewayListenerHasAHeaderTimeout(t *testing.T) {
	if srv := newHTTPServer("127.0.0.1:0", http.NotFoundHandler()); srv.ReadHeaderTimeout <= 0 {
		t.Fatal("the gateway listener has no ReadHeaderTimeout")
	}
}

// A /call body over the frame limit is refused instead of read without bound (GW-12).
func TestAnOversizedCallBodyIsRefused(t *testing.T) {
	gw := NewGateway()
	gw.globalHostID = "the-app" // past the no-host check; the body is read first
	body := `{"method":"x","args":{"blob":"` + strings.Repeat("a", maxMessageSize) + `"}}`
	r := httptest.NewRequest(http.MethodPost, "/call", bytes.NewReader([]byte(body)))
	w := httptest.NewRecorder()
	gw.HandleHTTPCall(w, r)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("an oversized body got %d, want 400", w.Code)
	}
}

// Only the proven host sends 2 MB frames; every other WebSocket peer gets the 2026-03 limit (GW-13).
func TestOnlyTheHostGetsTheLargeFrameLimit(t *testing.T) {
	if readLimitFor(true) != maxMessageSize {
		t.Fatal("the proven host lost the large limit its answers need")
	}
	if readLimitFor(false) != maxCallerMessageSize || maxCallerMessageSize >= maxMessageSize {
		t.Fatal("a caller that is not the host may send 2 MB frames")
	}
}
