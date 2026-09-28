package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// identifyRaw dials, identifies and returns the first reply, or the read error if the gateway closed.
func identifyRaw(t *testing.T, ctx context.Context, wsURL string, env Envelope) (*websocket.Conn, Envelope, error) {
	t.Helper()
	conn, _ := dialAndRead(t, ctx, wsURL)
	env.Type = "identify"
	sendEnvelope(t, ctx, conn, env)
	_, data, err := conn.Read(ctx)
	var reply Envelope
	if err == nil {
		json.Unmarshal(data, &reply)
	}
	return conn, reply, err
}

// keepReading is the read loop a live client runs; it is what answers the gateway's pings.
func keepReading(ctx context.Context, conn *websocket.Conn) {
	go func() {
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	}()
}

// A live caller keeps its ID: a newcomer without the same credential is refused (GW-02).
func TestALiveCallersIDCannotBeTaken(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	owner, w, err := identifyRaw(t, ctx, wsURL, Envelope{SenderID: "cli", Credential: "p42_owner"})
	if err != nil || w.Type != "welcome" {
		t.Fatalf("owner: %v %+v", err, w)
	}
	defer owner.CloseNow()
	keepReading(ctx, owner)

	thief, reply, err := identifyRaw(t, ctx, wsURL, Envelope{SenderID: "cli", Credential: "p42_thief"})
	defer thief.CloseNow()
	if err == nil {
		t.Fatalf("a newcomer took a live caller's id: %+v", reply)
	}
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("expected a policy-violation close, got %v", err)
	}
}

// The same caller reconnecting with its credential replaces its own connection.
func TestTheSameCredentialReclaimsItsID(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	first, _, _ := identifyRaw(t, ctx, wsURL, Envelope{SenderID: "cli", Credential: "p42_owner"})
	defer first.CloseNow()
	keepReading(ctx, first)
	second, w, err := identifyRaw(t, ctx, wsURL, Envelope{SenderID: "cli", Credential: "p42_owner"})
	defer second.CloseNow()
	if err != nil || w.Type != "welcome" {
		t.Fatalf("same credential refused: %v %+v", err, w)
	}
}

// A holder that no longer answers pings is dead, so an ordinary reconnect gets its ID back.
func TestADeadHoldersIDCanBeReclaimed(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stale, _, _ := identifyRaw(t, ctx, wsURL, Envelope{SenderID: "cli"}) // never reads again
	defer stale.CloseNow()
	fresh, w, err := identifyRaw(t, ctx, wsURL, Envelope{SenderID: "cli"})
	defer fresh.CloseNow()
	if err != nil || w.Type != "welcome" {
		t.Fatalf("reconnect over a dead holder refused: %v %+v", err, w)
	}
}

// A replaced host connection must not clear the host slot its successor holds.
func TestAReplacedHostDoesNotClearItsSuccessor(t *testing.T) {
	gw := NewGateway()
	cred, _ := ReadHostCredential(strings.NewReader("the-host\n"))
	gw.SetHostCredential(cred)
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	host := Envelope{SenderID: "the-app", IsHost: true, HostCredential: "the-host"}
	first, _, _ := identifyRaw(t, ctx, wsURL, host)
	defer first.CloseNow()
	keepReading(ctx, first)
	second, w, err := identifyRaw(t, ctx, wsURL, host)
	defer second.CloseNow()
	if err != nil || w.Type != "welcome" {
		t.Fatalf("the host was refused its own id: %v %+v", err, w)
	}
	time.Sleep(100 * time.Millisecond) // the replaced connection's removePeer runs
	gw.mu.RLock()
	defer gw.mu.RUnlock()
	if gw.globalHostID != "the-app" {
		t.Fatalf("the replaced connection cleared its successor's host slot: %q", gw.globalHostID)
	}
}
