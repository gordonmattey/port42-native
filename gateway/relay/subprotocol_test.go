package relay

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// #220: relay connections negotiate the "port42" WebSocket subprotocol. The relay echoes it to a
// client that offers it and still accepts one that offers none; the Mac client offers it and still
// works with a relay that predates it.

func TestTheRelayEchoesPort42ToAClientThatOffersIt(t *testing.T) {
	w := newRelayWorld(t, DefaultLimits)
	conn, _, err := websocket.Dial(w.ctx, w.url, &websocket.DialOptions{Subprotocols: []string{Subprotocol}})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	if got := conn.Subprotocol(); got != "port42" {
		t.Fatalf("the relay answered subprotocol %q, want port42", got)
	}
	if ch, err := readControl(w.ctx, conn); err != nil || ch.T != "challenge" {
		t.Fatalf("no challenge after negotiating port42: %+v %v", ch, err)
	}
}

func TestTheRelayStillAcceptsAClientThatOffersNone(t *testing.T) {
	w := newRelayWorld(t, DefaultLimits)
	conn, _, err := websocket.Dial(w.ctx, w.url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	if got := conn.Subprotocol(); got != "" {
		t.Fatalf("a client that offered nothing was given subprotocol %q", got)
	}
	if ch, err := readControl(w.ctx, conn); err != nil || ch.T != "challenge" {
		t.Fatalf("an older client was not served: %+v %v", ch, err)
	}
}

func TestTheMacClientOffersPort42AndWorksWithAnOlderRelay(t *testing.T) {
	offered := make(chan string, 1)
	// An older relay: it accepts with no subprotocol, then sends its challenge.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offered <- r.Header.Get("Sec-WebSocket-Protocol")
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		_ = writeControl(r.Context(), c, Control{T: "challenge", Relay: r.Host, Nonce: "n"})
		_, _, _ = c.Read(r.Context()) // the hello; then this relay goes away
	}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, err := connect(ctx, "ws"+strings.TrimPrefix(srv.URL, "http")+"/v1", newKey(t), "host")
	if got := <-offered; got != "port42" {
		t.Fatalf("the Mac client offered %q, want port42", got)
	}
	// It got past the handshake to the relay's challenge: the missing echo did not fail the dial.
	if err != nil && strings.Contains(err.Error(), "Sec-WebSocket-Protocol") {
		t.Fatalf("an older relay's handshake was refused: %v", err)
	}
	if err != nil && strings.Contains(err.Error(), "no challenge") {
		t.Fatalf("the client never reached the older relay's challenge: %v", err)
	}
}
