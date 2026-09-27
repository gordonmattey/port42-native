package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/port42/gateway/relay"
	"github.com/port42/gateway/transport"
)

// Nautilus Phase 4, 4.4: the door serves a caller on another instance through a relay, end to end in
// process. The app (the host connection) sees the guest's key as the transport authenticated it,
// attested; the relay in between carries only Noise ciphertext.
func TestTheDoorServesARemoteCallThroughARelay(t *testing.T) {
	rsrv := httptest.NewServer(relay.NewServer(relay.DefaultLimits).Handler())
	defer rsrv.Close()
	relayURL := "ws" + strings.TrimPrefix(rsrv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// This instance: a gateway with its host credential, attestation key and peer key.
	gw := NewGateway()
	cred, _ := ReadHostCredential(strings.NewReader("the-host\n"))
	gw.SetHostCredential(cred)
	gw.SetAttestKey(testAttestKey)
	_, hostKey, _ := ed25519.GenerateKey(rand.Reader)
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	app, _ := dialAndRead(t, ctx, wsURL)
	defer app.CloseNow()
	sendEnvelope(t, ctx, app, Envelope{Type: "identify", SenderID: "the-app", IsHost: true, HostCredential: "the-host"})
	readEnvelope(t, ctx, app)

	here := relay.NewTransport(hostKey, []string{relayURL})
	here.Run(ctx)
	go gw.ServeRemote(ctx, here)

	// Another instance dials this one by its peer id.
	_, guestKey, _ := ed25519.GenerateKey(rand.Reader)
	guest := relay.NewTransport(guestKey, []string{relayURL})
	var s transport.Session
	var err error
	for i := 0; i < 50; i++ {
		if s, err = guest.Dial(ctx, here.PeerID()); err == nil {
			break
		}
		var r *relay.Refusal
		if !errors.As(err, &r) || r.Code != relay.CodeHostOffline {
			t.Fatalf("dial: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("never reached the host: %v", err)
	}

	b, _ := json.Marshal(Envelope{Type: "call", Method: "ports.list", CallID: "via-relay"})
	s.Send(ctx, b)
	call := readEnvelope(t, ctx, app)
	if call.RemotePeer != guest.PeerID() || call.RemoteAttest != Attest(testAttestKey, guest.PeerID()) {
		t.Fatalf("the app did not get the guest's attested key: %q", call.RemotePeer)
	}
	sendEnvelope(t, ctx, app, Envelope{Type: "response", TargetID: call.SenderID, CallID: "via-relay",
		Payload: json.RawMessage(`{"content":"[]"}`)})
	reply, err := s.Recv(ctx)
	if err != nil || !strings.Contains(string(reply), `"call_id":"via-relay"`) {
		t.Fatalf("the reply did not come back through the relay: %v %s", err, reply)
	}
}

func TestTheAppIsToldWhenItsInstanceIsRegisteredOnARelay(t *testing.T) {
	rsrv := httptest.NewServer(relay.NewServer(relay.DefaultLimits).Handler())
	relayURL := "ws" + strings.TrimPrefix(rsrv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	a := newInstance(t, ctx)
	a.gw.SetRelayState(relayURL, false)
	// Losing a relay is reported the same way; the client's detection of a dead connection is
	// relay_test's (an in-process server cannot drop a hijacked WebSocket to show it here).
	tr := relay.NewTransport(a.gw.peerKey(), []string{relayURL})
	tr.OnState = a.gw.SetRelayState
	tr.Run(ctx)

	want := func(code string) {
		t.Helper()
		for {
			e := readEnvelope(t, ctx, a.app)
			if e.Type == "relay_state" && len(e.Relays) == 1 && e.Relays[0] == relayURL && e.Code == code {
				return
			}
		}
	}
	want("registered")
	rsrv.Close()
}
