package relay

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// The client's address is never taken from X-Forwarded-For, whose first entry the client writes, and
// from CF-Connecting-IP only when the relay says it runs behind Cloudflare (REL-01).
func TestTheClientAddressCannotBeWrittenByTheClient(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/v1", nil)
	r.RemoteAddr = "198.51.100.9:5000"
	r.Header.Set("X-Forwarded-For", "203.0.113.1")
	r.Header.Set("CF-Connecting-IP", "203.0.113.2")

	direct := NewServer(DefaultLimits)
	if got := direct.clientIP(r); got != "198.51.100.9" {
		t.Fatalf("a directly reached relay used %q, want the connection's own address", got)
	}
	behindCF := NewServer(DefaultLimits)
	behindCF.TrustCloudflare = true
	if got := behindCF.clientIP(r); got != "203.0.113.2" {
		t.Fatalf("behind Cloudflare got %q, want CF-Connecting-IP", got)
	}
	r.Header.Del("CF-Connecting-IP")
	if got := behindCF.clientIP(r); got != "198.51.100.9" {
		t.Fatalf("with no CF header got %q, want the connection's address", got)
	}
}

// rawGuest opens one session to `to` from address ip (through CF-Connecting-IP) and returns the
// relay's refusal code, or "" when the open was not refused. The connection stays open until the
// test ends, so an admitted session keeps counting.
func rawGuest(t *testing.T, ctx context.Context, url, ip, to string) string {
	t.Helper()
	h := http.Header{}
	h.Set("CF-Connecting-IP", ip)
	c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: h})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() })
	read := func(d time.Duration) (Control, bool) {
		rctx, cancel := context.WithTimeout(ctx, d)
		defer cancel()
		_, b, err := c.Read(rctx)
		if err != nil {
			return Control{}, false
		}
		var m Control
		json.Unmarshal(b, &m)
		return m, true
	}
	ch, _ := read(2 * time.Second)
	key := newKey(t)
	sig := ed25519.Sign(key, helloText(ch.Relay, ch.Nonce, "guest"))
	hello, _ := json.Marshal(Control{T: "hello", Role: "guest", Key: idOf(key), Sig: base64.StdEncoding.EncodeToString(sig)})
	c.Write(ctx, websocket.MessageText, hello)
	if ok, _ := read(2 * time.Second); ok.T != "ok" {
		t.Fatalf("hello refused: %+v", ok)
	}
	open, _ := json.Marshal(Control{T: "open", To: to})
	c.Write(ctx, websocket.MessageText, open)
	if m, ok := read(500 * time.Millisecond); ok && m.T == "error" {
		return m.Code
	}
	return ""
}

func limitsWorld(t *testing.T, l Limits) (context.Context, string, string) {
	t.Helper()
	srv := NewServer(l)
	srv.TrustCloudflare = true
	hs := httptest.NewServer(srv.Handler())
	t.Cleanup(hs.Close)
	url := "ws" + strings.TrimPrefix(hs.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	host := NewTransport(newKey(t), []string{url})
	host.Run(ctx)
	for i := 0; i < 50; i++ { // wait for the host to register
		srv.mu.Lock()
		_, up := srv.hosts[host.PeerID()]
		srv.mu.Unlock()
		if up {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	return ctx, url, host.PeerID()
}

// One source spending a host's open allowance does not lock anyone else out of that host (REL-01).
// The allowance used to be global per host, so anyone who knew a peer id could keep it unreachable.
func TestOneSourceCannotLockOthersOutOfAHost(t *testing.T) {
	l := Limits{MaxFrame: 64<<10 + 64, SessionsPerHost: 100, SessionsPerKey: 100, SessionsPerHostIP: 100,
		OpensPerIPMin: 100, OpensPerHostMin: 2, AcceptTimeout: 2 * time.Second, Idle: time.Minute}
	ctx, url, to := limitsWorld(t, l)
	for i := 0; i < 2; i++ {
		if code := rawGuest(t, ctx, url, "203.0.113.1", to); code != "" {
			t.Fatalf("open %d from the first source refused: %s", i, code)
		}
	}
	if code := rawGuest(t, ctx, url, "203.0.113.1", to); code != CodeRateLimited {
		t.Fatalf("the first source's third open: got %q, want rate_limited", code)
	}
	if code := rawGuest(t, ctx, url, "203.0.113.2", to); code != "" {
		t.Fatalf("another source was locked out of the host: %s", code)
	}
}

// One source holds at most SessionsPerHostIP sessions with a host, so it cannot fill the host's
// sessions with ones that never complete.
func TestOneSourceHoldsBoundedSessionsWithAHost(t *testing.T) {
	l := Limits{MaxFrame: 64<<10 + 64, SessionsPerHost: 100, SessionsPerKey: 100, SessionsPerHostIP: 1,
		OpensPerIPMin: 100, OpensPerHostMin: 100, AcceptTimeout: 2 * time.Second, Idle: time.Minute}
	ctx, url, to := limitsWorld(t, l)
	if code := rawGuest(t, ctx, url, "203.0.113.1", to); code != "" {
		t.Fatalf("first session refused: %s", code)
	}
	if code := rawGuest(t, ctx, url, "203.0.113.1", to); code != CodeLimit {
		t.Fatalf("a second held session from one source: got %q, want limit", code)
	}
	if code := rawGuest(t, ctx, url, "203.0.113.2", to); code != "" {
		t.Fatalf("another source was refused: %s", code)
	}
}

// The relay and invite-page listeners have a header timeout (GW-12).
func TestTheRelayListenerHasAHeaderTimeout(t *testing.T) {
	if srv := NewHTTPServer(":0", http.NotFoundHandler()); srv.ReadHeaderTimeout <= 0 {
		t.Fatal("the relay listener has no ReadHeaderTimeout")
	}
}

// One address holds at most ConnsPerIP relay connections at once (GW-12).
func TestOneAddressHoldsBoundedConnections(t *testing.T) {
	l := DefaultLimits
	l.ConnsPerIP = 2
	srv := NewServer(l)
	srv.TrustCloudflare = true
	hs := httptest.NewServer(srv.Handler())
	defer hs.Close()
	url := "ws" + strings.TrimPrefix(hs.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	dial := func(ip string) error {
		h := http.Header{}
		h.Set("CF-Connecting-IP", ip)
		c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: h})
		if err == nil {
			t.Cleanup(func() { c.CloseNow() })
		}
		return err
	}
	for i := 0; i < 2; i++ {
		if err := dial("203.0.113.1"); err != nil {
			t.Fatalf("connection %d refused: %v", i, err)
		}
	}
	if err := dial("203.0.113.1"); err == nil {
		t.Fatal("a third connection from one address was accepted")
	}
	if err := dial("203.0.113.2"); err != nil {
		t.Fatalf("another address was refused: %v", err)
	}
}
