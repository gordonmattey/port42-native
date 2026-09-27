package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/port42/gateway/relay"
	"github.com/port42/gateway/transport"
)

// instance is one Port42 in a test: a gateway with its credential, key and attestation key, and the
// app's host connection to it.
type instance struct {
	gw  *Gateway
	app *websocket.Conn
	id  string
	url string
}

func newInstance(t *testing.T, ctx context.Context) instance {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	rand.Read(seed)
	gw := NewGateway()
	cred, rest := ReadHostCredential(strings.NewReader("the-host\n" + base64.StdEncoding.EncodeToString(seed) + "\n"))
	gw.SetHostCredential(cred)
	gw.SetPeerIdentity(ReadPeerIdentity(bufio.NewReader(rest)))
	gw.SetAttestKey(testAttestKey)
	srv, url := setupTestServer(gw)
	t.Cleanup(srv.Close)
	app, _ := dialAndRead(t, ctx, url)
	t.Cleanup(func() { app.CloseNow() })
	sendEnvelope(t, ctx, app, Envelope{Type: "identify", SenderID: "app", IsHost: true, HostCredential: "the-host"})
	readEnvelope(t, ctx, app)
	return instance{gw: gw, app: app, id: gw.selfPeerID(), url: url}
}

func TestAnAppCallsAPortOnAnotherInstanceThroughItsGateway(t *testing.T) {
	rsrv := httptest.NewServer(relay.NewServer(relay.DefaultLimits).Handler())
	defer rsrv.Close()
	relayURL := "ws" + strings.TrimPrefix(rsrv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	a, b := newInstance(t, ctx), newInstance(t, ctx)
	here := relay.NewTransport(a.gw.peerKey(), []string{relayURL})
	here.Run(ctx)
	go a.gw.ServeRemote(ctx, here)
	time.Sleep(100 * time.Millisecond) // A registers on the relay

	// B's app asks its gateway to call a port on A.
	sendEnvelope(t, ctx, b.app, Envelope{Type: "remote_call", CallID: "out-1", Method: "port.subscribe",
		Args: json.RawMessage(`{"id":"P"}`), ToPeer: a.id, Relays: []string{relayURL},
		Actor: &Actor{ID: "c-1", Name: "wise-tern", Kind: "companion"}})

	// A's app sees an ordinary remote caller: B's key, attested, and who on B made the call.
	call := readEnvelope(t, ctx, a.app)
	if call.Method != "port.subscribe" || call.RemotePeer != b.id || call.RemoteAttest != Attest(testAttestKey, b.id) {
		t.Fatalf("A's app got %+v", call)
	}
	if call.Actor == nil || *call.Actor != (Actor{ID: "c-1", Name: "wise-tern", Kind: "companion"}) {
		t.Fatalf("the actor did not cross: %+v", call.Actor)
	}
	sendEnvelope(t, ctx, a.app, Envelope{Type: "stream", TargetID: call.SenderID, CallID: call.CallID, Payload: json.RawMessage(`{"n":1}`)})
	sendEnvelope(t, ctx, a.app, Envelope{Type: "response", TargetID: call.SenderID, CallID: call.CallID, Payload: json.RawMessage(`{"done":true}`)})

	// B's app gets both, on its own call id, marked as from A.
	for _, want := range []string{"stream", "response"} {
		e := readEnvelope(t, ctx, b.app)
		if e.Type != want || e.CallID != "out-1" || e.RemotePeer != a.id {
			t.Fatalf("B's app got %+v, want a %s for out-1 from A", e, want)
		}
	}

	// A second call reuses the session: A still has one remote session.
	sendEnvelope(t, ctx, b.app, Envelope{Type: "remote_call", CallID: "out-2", Method: "ports.list",
		ToPeer: a.id, Relays: []string{relayURL}})
	call2 := readEnvelope(t, ctx, a.app)
	if call2.SenderID != call.SenderID {
		t.Fatalf("a second call dialled again: session %q then %q", call.SenderID, call2.SenderID)
	}
}

func TestACallToAnInstanceNobodyCanReachFailsAtOnce(t *testing.T) {
	rsrv := httptest.NewServer(relay.NewServer(relay.DefaultLimits).Handler())
	defer rsrv.Close()
	relayURL := "ws" + strings.TrimPrefix(rsrv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	b := newInstance(t, ctx)
	_, nobody, _ := ed25519.GenerateKey(rand.Reader)
	sendEnvelope(t, ctx, b.app, Envelope{Type: "remote_call", CallID: "out-x", Method: "ports.list",
		ToPeer: transport.PeerID(nobody.Public().(ed25519.PublicKey)), Relays: []string{relayURL}})
	if e := readEnvelope(t, ctx, b.app); e.Type != "error" || e.CallID != "out-x" || e.Code != CodeHostOffline {
		t.Fatalf("got %+v, want host_offline for out-x", e)
	}
}

func TestOnlyTheHostMakesRemoteCalls(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	b := newInstance(t, ctx)
	caller := identified(t, ctx, b.url, "a-local-caller", false)
	defer caller.CloseNow()
	sendEnvelope(t, ctx, caller, Envelope{Type: "remote_call", CallID: "sneak", Method: "ports.list",
		ToPeer: "x", Relays: []string{"wss://relay"}})
	if e := readEnvelope(t, ctx, caller); e.Type != "error" || e.CallID != "sneak" || e.Code != CodeUnknownMethod {
		t.Fatalf("a caller used this instance's key to call out: %+v", e)
	}
}
