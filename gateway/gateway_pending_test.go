package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// A caller that gives up takes its call with it (#247): the gateway tells the host, so a permission
// card the call waits on is withdrawn and a late click acts for nobody. And a call the host says is
// waiting on a person is kept open long enough for a person to answer.

// rawHost identifies as the host and hands every envelope it receives to the test.
func rawHost(t *testing.T, ctx context.Context, wsURL string) (*websocket.Conn, <-chan Envelope) {
	t.Helper()
	conn, first := dialAndRead(t, ctx, wsURL)
	if first.Type != "no_auth" {
		t.Fatalf("expected no_auth, got %s", first.Type)
	}
	sendEnvelope(t, ctx, conn, Envelope{Type: "identify", SenderID: "host-peer", SenderName: "Host", IsHost: true})
	if w := readEnvelope(t, ctx, conn); w.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", w.Type)
	}
	got := make(chan Envelope, 16)
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env Envelope
			if json.Unmarshal(data, &env) == nil {
				got <- env
			}
		}
	}()
	return conn, got
}

func next(t *testing.T, got <-chan Envelope, typ string, within time.Duration) Envelope {
	t.Helper()
	deadline := time.After(within)
	for {
		select {
		case env := <-got:
			if env.Type == typ {
				return env
			}
		case <-deadline:
			t.Fatalf("no %q reached the host within %v", typ, within)
			return Envelope{}
		}
	}
}

func shortWaits(t *testing.T, call, approval time.Duration) {
	oldCall, oldApproval := callWait, approvalWait
	callWait, approvalWait = call, approval
	t.Cleanup(func() { callWait, approvalWait = oldCall, oldApproval })
}

func postCall(srvURL string) (int, map[string]any) {
	body, _ := json.Marshal(map[string]any{"method": "companions.delete", "args": map[string]any{}})
	resp, err := http.Post(srvURL+"/call", "application/json", bytes.NewReader(body))
	if err != nil {
		return 0, nil
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestAnHTTPCallThatTimesOutIsCancelledOnTheHost(t *testing.T) {
	shortWaits(t, 300*time.Millisecond, 5*time.Second)
	gw := NewGateway()
	srv, wsURL := setupTestServerWithCall(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, got := rawHost(t, ctx, wsURL)
	defer conn.CloseNow()

	status, _ := postCall(srv.URL) // the host never answers
	if status != http.StatusGatewayTimeout {
		t.Fatalf("status %d, want 504", status)
	}
	call := next(t, got, "call", time.Second)
	if c := next(t, got, "cancel", 2*time.Second); c.CallID != call.CallID {
		t.Fatalf("cancel names %q, want the timed-out call %q", c.CallID, call.CallID)
	}
}

func TestACallWaitingOnAPersonIsKeptOpen(t *testing.T) {
	shortWaits(t, 300*time.Millisecond, 5*time.Second)
	gw := NewGateway()
	srv, wsURL := setupTestServerWithCall(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, got := rawHost(t, ctx, wsURL)
	defer conn.CloseNow()

	type result struct {
		status int
		out    map[string]any
	}
	done := make(chan result, 1)
	go func() { s, o := postCall(srv.URL); done <- result{s, o} }()

	call := next(t, got, "call", time.Second)
	sendEnvelope(t, ctx, conn, Envelope{Type: "pending", CallID: call.CallID, TargetID: call.SenderID})
	time.Sleep(900 * time.Millisecond) // three times the normal wait: the person is reading the card
	sendEnvelope(t, ctx, conn, Envelope{Type: "response", CallID: call.CallID, TargetID: call.SenderID,
		Payload: json.RawMessage(`{"ok":true}`)})

	r := <-done
	if r.status != http.StatusOK || r.out["ok"] != true {
		t.Fatalf("a call waiting on a person timed out: status %d, %v", r.status, r.out)
	}
}

func TestAWebSocketCallerThatLeavesIsCancelledOnTheHost(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServerWithCall(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, got := rawHost(t, ctx, wsURL)
	defer conn.CloseNow()

	caller, first := dialAndRead(t, ctx, wsURL)
	if first.Type != "no_auth" {
		t.Fatalf("expected no_auth, got %s", first.Type)
	}
	sendEnvelope(t, ctx, caller, Envelope{Type: "identify", SenderID: "ws-caller", SenderName: "Caller"})
	readEnvelope(t, ctx, caller) // welcome
	sendEnvelope(t, ctx, caller, Envelope{Type: "call", CallID: "c-1", Method: "companions.delete",
		Args: json.RawMessage(`{}`)})
	call := next(t, got, "call", time.Second)

	caller.Close(websocket.StatusNormalClosure, "gone")
	c := next(t, got, "cancel", 2*time.Second)
	if c.CallID != call.CallID || c.SenderID != "ws-caller" {
		t.Fatalf("cancel %+v, want call %q from ws-caller", c, call.CallID)
	}
}
