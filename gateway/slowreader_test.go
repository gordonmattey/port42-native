package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// A destination that stops reading holds up only itself (outq). Before it, the host's read loop wrote each
// frame straight to its destination, so one caller that stopped reading, or a slow relay, stopped every answer
// on the machine: the 20 second freezes on Dev6 (2026-10-02).

func shortWrites(t *testing.T) {
	t.Helper()
	was, wasLen := outqWriteTimeout, outqLen
	outqWriteTimeout, outqLen = time.Second, 16
	t.Cleanup(func() { outqWriteTimeout, outqLen = was, wasLen })
}

func TestACallerThatStopsReadingHoldsUpOnlyItself(t *testing.T) {
	shortWrites(t)
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	hostConn, got := rawHost(t, ctx, wsURL)
	defer hostConn.CloseNow()
	stuck := identified(t, ctx, wsURL, "stuck", false) // subscribes, then never reads again
	defer stuck.CloseNow()
	busy := identified(t, ctx, wsURL, "busy", false)
	defer busy.CloseNow()

	sendEnvelope(t, ctx, stuck, Envelope{Type: "call", Method: "port.subscribe", CallID: "s1"})
	next(t, got, "call", 3*time.Second)

	// Far more than the sockets between here and the stuck caller hold.
	blob := json.RawMessage(`{"blob":"` + strings.Repeat("x", 1<<20) + `"}`)
	flooded := make(chan struct{})
	go func() {
		defer close(flooded)
		for i := 0; i < 40; i++ {
			if sendErr := sendQuiet(ctx, hostConn, Envelope{Type: "stream", CallID: "s1", TargetID: "stuck", Payload: blob}); sendErr != nil {
				return
			}
		}
	}()
	// The gateway takes them all at once, or (as it was) stops reading the app partway.
	select {
	case <-flooded:
	case <-time.After(3 * time.Second):
	}

	sendEnvelope(t, ctx, busy, Envelope{Type: "call", Method: "whoami", CallID: "b1"})
	call := next(t, got, "call", 3*time.Second)
	if call.CallID != "b1" {
		t.Fatalf("the host got %+v", call)
	}
	go sendQuiet(ctx, hostConn, Envelope{Type: "response", CallID: "b1", TargetID: "busy", Payload: json.RawMessage(`{"content":"ok"}`)})

	answered := make(chan Envelope, 1)
	go func() {
		if _, data, err := busy.Read(ctx); err == nil {
			var env Envelope
			json.Unmarshal(data, &env)
			answered <- env
		}
	}()
	select {
	case env := <-answered:
		if env.Type != "response" || env.CallID != "b1" {
			t.Fatalf("busy got %+v", env)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a caller that stopped reading held up another caller's answer")
	}
}

func TestAGuestThatStopsReadingHoldsUpOnlyItself(t *testing.T) {
	shortWrites(t)
	ctx, host, hostSend, guest, wsURL := remoteWorld(t, testAttestKey)
	busy := identified(t, ctx, wsURL, "busy", false)
	defer busy.CloseNow()

	guestSend(t, ctx, guest, Envelope{Type: "call", Method: "port.subscribe", CallID: "g1"})
	sub := host()
	// More events than the session to the guest buffers; the guest reads none of them.
	for i := 0; i < 200; i++ {
		hostSend(Envelope{Type: "stream", CallID: "g1", TargetID: sub.SenderID, Payload: json.RawMessage(`{"n":1}`)})
	}

	sendEnvelope(t, ctx, busy, Envelope{Type: "call", Method: "whoami", CallID: "b1"})
	if call := host(); call.CallID != "b1" {
		t.Fatalf("the host got %+v", call)
	}
	hostSend(Envelope{Type: "response", CallID: "b1", TargetID: "busy", Payload: json.RawMessage(`{"content":"ok"}`)})
	short, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, data, err := busy.Read(short)
	if err != nil {
		t.Fatalf("a guest that stopped reading held up a local caller's answer: %v", err)
	}
	var env Envelope
	json.Unmarshal(data, &env)
	if env.Type != "response" || env.CallID != "b1" {
		t.Fatalf("busy got %+v", env)
	}
}

func TestTheAppIsNeverDroppedForFallingBehind(t *testing.T) {
	q := newOutq(func(ctx context.Context, _ []byte) error { <-ctx.Done(); return nil }, func(string) {})
	defer q.end()
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	var err error
	for i := 0; i < outqLen+5 && err == nil; i++ {
		err = q.put(ctx, []byte("x"), true)
	}
	if err != context.DeadlineExceeded {
		t.Fatalf("the app's sender should wait for room, got %v", err)
	}
	select {
	case <-q.done:
		t.Fatal("the app's queue was dropped for falling behind")
	default:
	}
}

// sendQuiet writes a frame from a goroutine, where t.Fatalf may not be called.
func sendQuiet(ctx context.Context, conn *websocket.Conn, env Envelope) error {
	data, err := json.Marshal(env)
	if err != nil {
		return err
	}
	return conn.Write(ctx, websocket.MessageText, data)
}
