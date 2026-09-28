package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// Only the host a call went to can answer it (GW-08). Before, any local peer could send a response
// or stream frame naming any caller and call_id, local or remote, and the gateway delivered it.
func TestAForgedAnswerFromAnotherPeerIsDropped(t *testing.T) {
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
	forger := identified(t, ctx, wsURL, "forger", false)
	defer forger.CloseNow()

	sendEnvelope(t, ctx, caller, Envelope{Type: "call", Method: "x", CallID: "c1"})
	if got := readEnvelope(t, ctx, host); got.Type != "call" {
		t.Fatalf("host did not get the call: %+v", got)
	}
	for _, typ := range []string{"stream", "response"} {
		sendEnvelope(t, ctx, forger, Envelope{Type: typ, CallID: "c1", TargetID: "caller",
			Payload: json.RawMessage(`{"content":"forged"}`)})
	}
	sendEnvelope(t, ctx, host, Envelope{Type: "response", CallID: "c1", TargetID: "caller",
		Payload: json.RawMessage(`{"content":"real"}`)})

	got := readEnvelope(t, ctx, caller)
	if got.Type != "response" || !strings.Contains(string(got.Payload), "real") {
		t.Fatalf("the caller received a forged frame: %+v", got)
	}

	// The call is over, so a second response, even from the host, has nothing to answer.
	sendEnvelope(t, ctx, host, Envelope{Type: "response", CallID: "c1", TargetID: "caller",
		Payload: json.RawMessage(`{"content":"late"}`)})
	short, stop := context.WithTimeout(ctx, 200*time.Millisecond)
	defer stop()
	if _, data, err := caller.Read(short); err == nil {
		t.Fatalf("a response to a finished call was delivered: %s", data)
	}
}

// A remote session's calls are answered only by the host too.
func TestARemoteCallersAnswersComeOnlyFromTheHost(t *testing.T) {
	g := NewGateway()
	g.expectAnswer("remote-abc", "r1", "the-app")
	if g.answeredBy(&Peer{ID: "forger"}, "remote-abc", "r1", true) {
		t.Fatal("a local peer answered a remote caller's call")
	}
	if !g.answeredBy(&Peer{ID: "the-app"}, "remote-abc", "r1", true) {
		t.Fatal("the host could not answer the remote call")
	}
	if g.answeredBy(&Peer{ID: "the-app"}, "remote-abc", "r1", true) {
		t.Fatal("a finished call was answered twice")
	}
}

// An HTTP /call is answered only by the host it went to.
func TestAnHTTPCallIgnoresANonHost(t *testing.T) {
	g := NewGateway()
	reply := make(chan Envelope, 1)
	g.httpCallbacks = map[string]httpCallback{"http-1": {reply: reply, host: "the-app"}}
	g.routeResponse(context.Background(), &Peer{ID: "forger"}, Envelope{Type: "response", CallID: "http-1", TargetID: "local-http"})
	select {
	case got := <-reply:
		t.Fatalf("a non-host answered an HTTP call: %+v", got)
	default:
	}
	if _, pending := g.httpCallbacks["http-1"]; !pending {
		t.Fatal("a non-host consumed the HTTP callback")
	}
}
