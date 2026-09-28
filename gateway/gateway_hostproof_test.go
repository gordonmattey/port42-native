package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// Host status comes from the checked claim, never from IsHost plus ID equality (GW-15). An impostor
// that identified under the host's ID with a wrong credential kept IsHost and matched globalHostID,
// so it was treated as the proven host.
func TestAnUnprovenClaimIsNeverTheHost(t *testing.T) {
	g := NewGateway()
	g.globalHostID = "the-app"
	impostor := &Peer{ID: "the-app", IsHost: true}
	if g.isHost(impostor) {
		t.Fatal("a peer with an unchecked is_host claim under the host's ID was treated as the host")
	}
	impostor.hostProven = true
	if !g.isHost(impostor) {
		t.Fatal("a proven host under globalHostID must be the host")
	}
}

// An unproven peer cannot identify under the live host's ID, so calls keep going to the real host.
func TestAnImpostorCannotTakeTheLiveHostsID(t *testing.T) {
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
	if w := readEnvelope(t, ctx, host); w.Type != "welcome" || w.SelfPeer == "" && gw.selfPeerID() != "" {
		t.Fatalf("host not welcomed as host: %+v", w)
	}

	for _, claim := range []Envelope{
		{Type: "identify", SenderID: "the-app", IsHost: true, HostCredential: "wrong"},
		{Type: "identify", SenderID: "the-app", IsHost: true},
		{Type: "identify", SenderID: "the-app"},
	} {
		imp, _ := dialAndRead(t, ctx, wsURL)
		sendEnvelope(t, ctx, imp, claim)
		_, _, err := imp.Read(ctx)
		imp.CloseNow()
		if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
			t.Fatalf("claim %+v: expected a policy-violation close, got %v", claim, err)
		}
	}

	caller := identified(t, ctx, wsURL, "caller", false)
	defer caller.CloseNow()
	sendEnvelope(t, ctx, caller, Envelope{Type: "call", Method: "x", CallID: "c1", Args: json.RawMessage(`{}`)})
	if got := readEnvelope(t, ctx, host); got.Type != "call" || got.CallID != "c1" {
		t.Fatalf("the real host no longer receives calls: %+v", got)
	}
}
