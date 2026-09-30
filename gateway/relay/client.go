package relay

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"sync"
	"time"

	"nhooyr.io/websocket"

	"github.com/port42/gateway/transport"
)

// Transport is transport.Transport through relays: this instance registers on each as a host, and
// reaches another instance by opening a session to its key. Every session is Noise end to end.
type Transport struct {
	key      ed25519.PrivateKey
	relays   []string
	incoming chan transport.Session
	// HandshakeTimeout bounds a Noise handshake, so a peer that stalls one holds nothing for long.
	HandshakeTimeout time.Duration
	// OnState, when set, is told each time this instance registers on a relay or loses it.
	OnState func(relayURL string, registered bool)
}

func NewTransport(key ed25519.PrivateKey, relays []string) *Transport {
	return &Transport{key: key, relays: relays, incoming: make(chan transport.Session, 16),
		HandshakeTimeout: 10 * time.Second}
}

func (t *Transport) PeerID() string { return transport.PeerID(t.key.Public().(ed25519.PublicKey)) }

func (t *Transport) Accept(ctx context.Context) (transport.Session, error) {
	select {
	case s := <-t.incoming:
		return s, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// PingEvery keeps a quiet connection alive through proxies in front of a relay: Cloudflare, for one,
// closes a WebSocket after about 100 seconds without traffic.
var PingEvery = 20 * time.Second

// PingTimeout is how long a ping may go unanswered before the connection is treated as dead.
var PingTimeout = 10 * time.Second

// keepAlive pings conn until stop closes or a ping fails, and then closes conn so its reader ends.
// nhooyr's Ping needs a concurrent reader, which every caller here has.
func keepAlive(conn *websocket.Conn, stop <-chan struct{}) {
	t := time.NewTicker(PingEvery)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(context.Background(), PingTimeout)
			err := conn.Ping(ctx)
			cancel()
			if err != nil {
				conn.CloseNow()
				return
			}
		}
	}
}

// Refusal is a relay's refusal, with a code a caller can act on (host_offline, refused, …).
type Refusal struct{ Code, Message string }

func (r *Refusal) Error() string { return r.Code + ": " + r.Message }

// SecureRelayURL reports whether a relay may be dialled: wss://, or ws:// to this machine for a relay
// run locally (REL-03). A plaintext relay named in an invite exposed the relay hello and let anyone on
// the path see who talks to whom; Noise still protected the calls themselves.
func SecureRelayURL(u *url.URL) bool {
	if u.Scheme == "wss" {
		return true
	}
	if u.Scheme != "ws" {
		return false
	}
	h := u.Hostname()
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// Subprotocol is the WebSocket subprotocol a relay connection speaks (Sec-WebSocket-Protocol), the
// name registered for Port42 with IANA (#220). A client offers it; a relay echoes it when offered.
// Offering it is safe against a relay that predates it: this library accepts a handshake that names no
// subprotocol (a browser does not, which is why the guest page falls back).
const Subprotocol = "port42"

// connect dials a relay and proves this key: it signs the relay's challenge, bound to the relay it
// meant to reach, so a signature cannot be replayed at another relay.
func connect(ctx context.Context, relayURL string, key ed25519.PrivateKey, role string) (*websocket.Conn, error) {
	u, err := url.Parse(relayURL)
	if err != nil {
		return nil, err
	}
	if !SecureRelayURL(u) {
		return nil, fmt.Errorf("refusing relay %q: a relay is reached over wss:// (REL-03)", relayURL)
	}
	conn, _, err := websocket.Dial(ctx, relayURL, &websocket.DialOptions{Subprotocols: []string{Subprotocol}})
	if err != nil {
		return nil, err
	}
	conn.SetReadLimit(int64(DefaultLimits.MaxFrame) + 1024)
	ch, err := readControl(ctx, conn)
	if err != nil || ch.T != "challenge" {
		conn.CloseNow()
		return nil, errors.New("the relay sent no challenge")
	}
	if ch.Relay != u.Host {
		conn.CloseNow()
		return nil, fmt.Errorf("the relay calls itself %q, not %q", ch.Relay, u.Host)
	}
	sig := ed25519.Sign(key, helloText(ch.Relay, ch.Nonce, role))
	if err := writeControl(ctx, conn, Control{T: "hello", Role: role,
		Key: transport.PeerID(key.Public().(ed25519.PublicKey)), Sig: base64.StdEncoding.EncodeToString(sig)}); err != nil {
		conn.CloseNow()
		return nil, err
	}
	ok, err := readControl(ctx, conn)
	if err != nil {
		conn.CloseNow()
		return nil, err
	}
	if ok.T != "ok" {
		conn.CloseNow()
		return nil, &Refusal{Code: ok.Code, Message: ok.Message}
	}
	return conn, nil
}

// --- host side ---

// Run keeps this instance registered on every relay until ctx ends, reconnecting after any drop
// (a relay restart, a network change, the Mac waking).
func (t *Transport) Run(ctx context.Context) {
	for _, r := range t.relays {
		go t.hostLoop(ctx, r)
	}
}

func (t *Transport) hostLoop(ctx context.Context, relayURL string) {
	backoff := time.Second
	for ctx.Err() == nil {
		conn, err := connect(ctx, relayURL, t.key, "host")
		if err != nil {
			log.Printf("[relay] %s: %v; retrying in %s", relayURL, err, backoff)
			select {
			case <-time.After(backoff):
			case <-ctx.Done():
				return
			}
			if backoff < 30*time.Second {
				backoff *= 2
			}
			continue
		}
		backoff = time.Second
		log.Printf("[relay] registered on %s as %s", relayURL, t.PeerID())
		if t.OnState != nil {
			t.OnState(relayURL, true)
		}
		t.serveHostConn(ctx, conn)
		log.Printf("[relay] lost %s; reconnecting", relayURL)
		if t.OnState != nil {
			t.OnState(relayURL, false)
		}
	}
}

type hostLink struct {
	conn    *websocket.Conn
	wmu     sync.Mutex
	mu      sync.Mutex
	streams map[string]*hostStream
}

func (l *hostLink) write(ctx context.Context, typ websocket.MessageType, b []byte) error {
	l.wmu.Lock()
	defer l.wmu.Unlock()
	return l.conn.Write(ctx, typ, b)
}

func (t *Transport) serveHostConn(ctx context.Context, conn *websocket.Conn) {
	l := &hostLink{conn: conn, streams: map[string]*hostStream{}}
	stop := make(chan struct{})
	go keepAlive(conn, stop)
	defer func() {
		close(stop)
		conn.CloseNow()
		l.mu.Lock()
		for _, s := range l.streams {
			s.closeRemote()
		}
		l.mu.Unlock()
	}()
	for {
		typ, b, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if typ == websocket.MessageBinary {
			if len(b) < 16 {
				continue
			}
			l.mu.Lock()
			s := l.streams[hex.EncodeToString(b[:16])]
			l.mu.Unlock()
			if s != nil {
				s.deliver(b[16:])
			}
			continue
		}
		var m Control
		if json.Unmarshal(b, &m) != nil {
			continue
		}
		switch m.T {
		case "incoming":
			sid, err := hex.DecodeString(m.SID)
			if err != nil || len(sid) != 16 {
				continue
			}
			s := &hostStream{link: l, sid: m.SID, sidBytes: sid, in: make(chan []byte, 256), done: make(chan struct{})}
			l.mu.Lock()
			l.streams[m.SID] = s
			l.mu.Unlock()
			l.write(ctx, websocket.MessageText, mustJSON(Control{T: "accept", SID: m.SID}))
			go t.respond(ctx, s)
		case "close":
			l.mu.Lock()
			s := l.streams[m.SID]
			delete(l.streams, m.SID)
			l.mu.Unlock()
			if s != nil {
				s.closeRemote()
			}
		}
	}
}

// respond runs the Noise responder on a new session; only an authenticated session is handed on.
func (t *Transport) respond(ctx context.Context, s *hostStream) {
	hctx, cancel := context.WithTimeout(ctx, t.HandshakeTimeout)
	defer cancel()
	sess, err := Respond(hctx, s, t.key)
	if err != nil {
		log.Printf("[relay] handshake refused: %v", err)
		s.Close()
		return
	}
	select {
	case t.incoming <- sess:
	case <-ctx.Done():
		s.Close()
	}
}

// hostStream is one session as the host sees it: frames tagged with the session id on the host's
// one connection.
type hostStream struct {
	link     *hostLink
	sid      string
	sidBytes []byte
	in       chan []byte
	once     sync.Once
	done     chan struct{}
}

func (s *hostStream) deliver(b []byte) {
	select {
	case s.in <- b:
	case <-s.done:
	default:
		// A reader this far behind is not reading: end the session rather than buffer without bound.
		s.Close()
	}
}

func (s *hostStream) closeRemote() { s.once.Do(func() { close(s.done) }) }

func (s *hostStream) SendFrame(ctx context.Context, b []byte) error {
	select {
	case <-s.done:
		return errors.New("session closed")
	default:
	}
	return s.link.write(ctx, websocket.MessageBinary, append(append(make([]byte, 0, len(b)+16), s.sidBytes...), b...))
}

func (s *hostStream) RecvFrame(ctx context.Context) ([]byte, error) {
	select {
	case b := <-s.in:
		return b, nil
	case <-s.done:
		return nil, errors.New("session closed")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (s *hostStream) Close() error {
	s.closeRemote()
	s.link.mu.Lock()
	delete(s.link.streams, s.sid)
	s.link.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return s.link.write(ctx, websocket.MessageText, mustJSON(Control{T: "close", SID: s.sid}))
}

// --- guest side ---

// Dial opens a session to another instance through the first relay that can reach it.
func (t *Transport) Dial(ctx context.Context, peer string) (transport.Session, error) {
	var last error = errors.New("no relays configured")
	for _, r := range t.relays {
		s, err := t.dialVia(ctx, r, peer)
		if err == nil {
			return s, nil
		}
		last = err
	}
	return nil, last
}

func (t *Transport) dialVia(ctx context.Context, relayURL, peer string) (transport.Session, error) {
	conn, err := connect(ctx, relayURL, t.key, "guest")
	if err != nil {
		return nil, err
	}
	if err := writeControl(ctx, conn, Control{T: "open", To: peer}); err != nil {
		conn.CloseNow()
		return nil, err
	}
	m, err := readControl(ctx, conn)
	if err != nil {
		conn.CloseNow()
		return nil, err
	}
	if m.T != "opened" {
		conn.CloseNow()
		return nil, &Refusal{Code: m.Code, Message: m.Message}
	}
	hctx, cancel := context.WithTimeout(ctx, t.HandshakeTimeout)
	defer cancel()
	g := &guestStream{conn: conn, stop: make(chan struct{})}
	go keepAlive(conn, g.stop)
	s, err := Initiate(hctx, g, t.key, peer)
	if err != nil {
		g.Close()
		return nil, err
	}
	return s, nil
}

// guestStream is one session as the guest sees it: its own connection, frames as they are.
type guestStream struct {
	conn *websocket.Conn
	wmu  sync.Mutex
	stop chan struct{}
	once sync.Once
}

func (g *guestStream) SendFrame(ctx context.Context, b []byte) error {
	g.wmu.Lock()
	defer g.wmu.Unlock()
	return g.conn.Write(ctx, websocket.MessageBinary, b)
}

func (g *guestStream) RecvFrame(ctx context.Context) ([]byte, error) {
	for {
		typ, b, err := g.conn.Read(ctx)
		if err != nil {
			return nil, err
		}
		if typ == websocket.MessageBinary {
			return b, nil
		}
	}
}

func (g *guestStream) Close() error {
	g.once.Do(func() { close(g.stop) })
	return g.conn.Close(websocket.StatusNormalClosure, "")
}
