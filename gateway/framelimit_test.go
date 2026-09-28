package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// A caller's frame over the 2026-03 limit closes its connection; the host's large answer does not (GW-13).
func TestACallersLargeFrameIsRefusedAndTheHostsIsNot(t *testing.T) {
	gw := NewGateway()
	cred, _ := ReadHostCredential(strings.NewReader("the-host\n"))
	gw.SetHostCredential(cred)
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	host, _ := dialAndRead(t, ctx, wsURL)
	defer host.CloseNow()
	sendEnvelope(t, ctx, host, Envelope{Type: "identify", SenderID: "the-app", IsHost: true, HostCredential: "the-host"})
	readEnvelope(t, ctx, host) // welcome
	caller := identified(t, ctx, wsURL, "caller", false)
	defer caller.CloseNow()

	big := `{"type":"call","method":"x","call_id":"c1","args":{"blob":"` + strings.Repeat("a", 200<<10) + `"}}`
	caller.Write(ctx, websocket.MessageText, []byte(big))
	if _, _, err := caller.Read(ctx); websocket.CloseStatus(err) != websocket.StatusMessageTooBig {
		t.Fatalf("a caller's 200 KB frame: got %v, want message too big", err)
	}

	answer := `{"type":"stream","target_id":"nobody","call_id":"x","payload":{"blob":"` + strings.Repeat("a", 200<<10) + `"}}`
	if err := host.Write(ctx, websocket.MessageText, []byte(answer)); err != nil {
		t.Fatalf("host write: %v", err)
	}
	go func() { // a client answers pings only while it reads
		for {
			if _, _, err := host.Read(ctx); err != nil {
				return
			}
		}
	}()
	if err := host.Ping(ctx); err != nil {
		t.Fatalf("the host's 200 KB frame closed its connection: %v", err)
	}
}
