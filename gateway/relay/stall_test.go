package relay

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// rawPeer speaks the relay's own protocol with no Noise on top, so a test can hold a socket that
// never reads, which a real client (always draining) cannot.
type rawPeer struct {
	t *testing.T
	c *websocket.Conn
}

func dialRaw(t *testing.T, ctx context.Context, url, role string) (*rawPeer, string) {
	t.Helper()
	c, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	c.SetReadLimit(1 << 20)
	t.Cleanup(func() { c.CloseNow() })
	p := &rawPeer{t: t, c: c}
	ch := p.control(ctx)
	key := newKey(t)
	sig := ed25519.Sign(key, helloText(ch.Relay, ch.Nonce, role))
	p.send(ctx, Control{T: "hello", Role: role, Key: idOf(key), Sig: base64.StdEncoding.EncodeToString(sig)})
	if ok := p.control(ctx); ok.T != "ok" {
		t.Fatalf("hello refused: %+v", ok)
	}
	return p, idOf(key)
}

func (p *rawPeer) send(ctx context.Context, m Control) {
	b, _ := json.Marshal(m)
	if err := p.c.Write(ctx, websocket.MessageText, b); err != nil {
		p.t.Fatalf("write: %v", err)
	}
}

func (p *rawPeer) control(ctx context.Context) Control {
	p.t.Helper()
	for {
		typ, b, err := p.c.Read(ctx)
		if err != nil {
			p.t.Fatalf("read: %v", err)
		}
		if typ == websocket.MessageText {
			var m Control
			json.Unmarshal(b, &m)
			return m
		}
	}
}

// One guest that stops reading must not stall the other sessions on its host (#124). The relay
// wrote each host frame straight to its guest from the host's single read loop, with no deadline,
// so once a silent guest's socket filled, every session that host had stopped, indefinitely: a cheap
// denial of service against anyone sharing through a public relay.
func TestAGuestThatStopsReadingDoesNotStallTheHostsOtherSessions(t *testing.T) {
	hs := httptest.NewServer(NewServer(DefaultLimits).Handler())
	t.Cleanup(hs.Close)
	url := "ws" + strings.TrimPrefix(hs.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	host, hostID := dialRaw(t, ctx, url, "host")
	open := func() (*rawPeer, string) {
		g, _ := dialRaw(t, ctx, url, "guest")
		g.send(ctx, Control{T: "open", To: hostID})
		in := host.control(ctx)
		if in.T != "incoming" {
			t.Fatalf("host got %+v, want incoming", in)
		}
		host.send(ctx, Control{T: "accept", SID: in.SID})
		if m := g.control(ctx); m.T != "opened" {
			t.Fatalf("guest got %+v, want opened", m)
		}
		return g, in.SID
	}
	frame := func(sid string, payload []byte) []byte {
		b, _ := hex.DecodeString(sid)
		return append(b, payload...)
	}

	_, silentSID := open() // never read from again
	reader, readerSID := open()

	// Flood the silent guest well past any socket buffer.
	chunk := make([]byte, 32<<10)
	flood := make(chan error, 1)
	go func() {
		for i := 0; i < 400; i++ { // 12.5 MB
			if err := host.c.Write(ctx, websocket.MessageBinary, frame(silentSID, chunk)); err != nil {
				flood <- err
				return
			}
		}
		flood <- nil
	}()
	select {
	case <-flood:
	case <-time.After(5 * time.Second):
		// The host's own write blocked: the relay stopped reading it, because it is stuck
		// writing to the silent guest. That is the stall.
	}

	// The other guest must still get its frame.
	wctx, wcancel := context.WithTimeout(ctx, 3*time.Second)
	defer wcancel()
	if err := host.c.Write(wctx, websocket.MessageBinary, frame(readerSID, []byte("still here"))); err != nil {
		t.Fatalf("the host could not send to its other guest: the relay stopped reading the host (%v)", err)
	}
	for {
		typ, b, err := reader.c.Read(wctx)
		if err != nil {
			t.Fatalf("the other guest got nothing: one silent guest stalled the host's sessions (%v)", err)
		}
		if typ == websocket.MessageBinary {
			if string(b) != "still here" {
				t.Fatalf("got %q", b)
			}
			return
		}
	}
}
