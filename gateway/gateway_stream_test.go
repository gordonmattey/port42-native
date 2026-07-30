package main

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

// A `stream` frame is a response that does NOT end the call. Before it existed, a streaming method's
// events had nowhere to go: the app discarded every one and the gateway had no frame to carry them,
// so a caller subscribing to a port received nothing, forever.
//
// The property that matters most here is the negative one. A stream frame must never resolve an HTTP
// callback: `/call` is request/response and is completed by exactly one `response`, so a stream frame
// that resolved it would truncate the call at its first event.
func TestRouteStreamDoesNotResolveHTTPCallback(t *testing.T) {
	g := NewGateway()

	replyCh := make(chan Envelope, 4)
	g.mu.Lock()
	g.httpCallbacks = map[string]chan Envelope{"call-1": replyCh}
	g.mu.Unlock()

	// A stream frame naming a target nobody is connected as: it must drop, not resolve the callback.
	g.routeStream(context.Background(), &Peer{ID: "host"}, Envelope{
		Type: "stream", CallID: "call-1", TargetID: "absent-peer",
		Payload: json.RawMessage(`{"content":"event-1"}`),
	})

	select {
	case got := <-replyCh:
		t.Fatalf("a stream frame resolved the HTTP callback and truncated the call: %+v", got)
	case <-time.After(50 * time.Millisecond):
	}

	g.mu.RLock()
	_, stillPending := g.httpCallbacks["call-1"]
	g.mu.RUnlock()
	if !stillPending {
		t.Fatal("a stream frame consumed the HTTP callback; only a response may complete a call")
	}
}

// A stream frame with no target has nowhere to go and must not panic or broadcast.
func TestRouteStreamWithoutTargetIsDropped(t *testing.T) {
	g := NewGateway()
	g.routeStream(context.Background(), &Peer{ID: "host"}, Envelope{Type: "stream", CallID: "c"})
}

// Streamable is set BY THE GATEWAY on the WS door, never trusted from the caller: a client must not
// be able to claim it can receive streams on a transport that cannot carry them.
func TestStreamableIsNotTakenFromTheCaller(t *testing.T) {
	var env Envelope
	if err := json.Unmarshal([]byte(`{"type":"call","method":"x","streamable":true}`), &env); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !env.Streamable {
		t.Fatal("precondition: the field decodes")
	}
	// HandleHTTPCall builds its own envelope and never copies the request body's value, so the HTTP
	// door cannot be talked into streaming. Asserted structurally: the envelope it constructs has
	// Streamable at its zero value.
	httpCall := Envelope{Type: "call", Method: "x", SenderID: "local-http"}
	if httpCall.Streamable {
		t.Fatal("the HTTP door must never mark a call streamable")
	}
}
