package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"nhooyr.io/websocket"

	"github.com/port42/gateway/transport"
)

// THE RELAY (docs/design-phase4-relay.md "The relay").
//
// It pairs a guest with a host by the host's key and forwards frames between them. It holds only
// who is connected, in memory. A host proves its key by signing a challenge, so nobody can register
// as a key it does not hold, and a guest asking for a key reaches that host or nobody. Everything
// after the pairing is Noise ciphertext: the relay cannot read it, and a changed frame fails to
// authenticate at the other end.

// Control is a relay control message (a WebSocket text frame). Data travels in binary frames.
type Control struct {
	T       string `json:"t"`
	Relay   string `json:"relay,omitempty"`
	Nonce   string `json:"nonce,omitempty"`
	Role    string `json:"role,omitempty"`
	Key     string `json:"key,omitempty"`
	Sig     string `json:"sig,omitempty"`
	To      string `json:"to,omitempty"`
	From    string `json:"from,omitempty"`
	SID     string `json:"sid,omitempty"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// Refusal codes a relay sends. host_offline is one the app already knows.
const (
	CodeHostOffline = "host_offline"
	CodeRefused     = "refused"
	CodeRateLimited = "rate_limited"
	CodeBadHello    = "bad_hello"
	CodeLimit       = "limit"
)

// helloText is what a client signs: the relay it meant to reach, the relay's nonce and its role. The
// relay name stops a signature made for one relay being replayed at another.
func helloText(relay, nonce, role string) []byte {
	return []byte("port42-relay-v1|" + relay + "|" + nonce + "|" + role)
}

// Limits bound what one host or guest can take from a relay.
type Limits struct {
	MaxFrame        int           // largest data frame, sid prefix included
	SessionsPerHost int           // open sessions one host can have
	SessionsPerKey  int           // open sessions one guest key can have
	OpensPerIPMin   int           // session requests one IP may make a minute
	OpensPerHostMin int           // session requests one host may receive a minute
	AcceptTimeout   time.Duration // how long a host has to accept
	Idle            time.Duration // a session with no frames either way is closed
}

var DefaultLimits = Limits{MaxFrame: 64<<10 + 64, SessionsPerHost: 32, SessionsPerKey: 4,
	OpensPerIPMin: 30, OpensPerHostMin: 10, AcceptTimeout: 15 * time.Second, Idle: 5 * time.Minute}

// Server is a relay. The zero value is not usable; call NewServer.
type Server struct {
	limits Limits

	mu       sync.Mutex
	hosts    map[string]*hostConn     // by host key
	sessions map[string]*relaySession // by sid
	perKey   map[string]int           // open sessions per guest key
	opensIP  map[string][]time.Time
	opensTo  map[string][]time.Time
}

func NewServer(l Limits) *Server {
	return &Server{limits: l, hosts: map[string]*hostConn{}, sessions: map[string]*relaySession{},
		perKey: map[string]int{}, opensIP: map[string][]time.Time{}, opensTo: map[string][]time.Time{}}
}

type hostConn struct {
	key  string
	conn *websocket.Conn
	wmu  sync.Mutex
	// the sessions this host has, by sid
	sessions map[string]*relaySession
}

func (h *hostConn) write(ctx context.Context, typ websocket.MessageType, b []byte) error {
	h.wmu.Lock()
	defer h.wmu.Unlock()
	return h.conn.Write(ctx, typ, b)
}

type relaySession struct {
	sid      string
	sidBytes []byte
	host     *hostConn
	guest    *websocket.Conn
	guestKey string
	accepted chan bool
	gmu      sync.Mutex
	last     atomic.Int64 // unix nanos of the last frame either way
}

func (s *relaySession) writeGuest(ctx context.Context, typ websocket.MessageType, b []byte) error {
	s.gmu.Lock()
	defer s.gmu.Unlock()
	return s.guest.Write(ctx, typ, b)
}

// Handler serves `/v1` (the relay) and `/health`.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/v1", s.serveWS)
	return mux
}

func writeControl(ctx context.Context, c *websocket.Conn, m Control) error {
	b, _ := json.Marshal(m)
	return c.Write(ctx, websocket.MessageText, b)
}

func readControl(ctx context.Context, c *websocket.Conn) (Control, error) {
	typ, b, err := c.Read(ctx)
	if err != nil {
		return Control{}, err
	}
	if typ != websocket.MessageText {
		return Control{}, errors.New("expected a control message")
	}
	var m Control
	return m, json.Unmarshal(b, &m)
}

func (s *Server) serveWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: []string{"*"}})
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(int64(s.limits.MaxFrame) + 1024)
	ctx := r.Context()

	var nb [16]byte
	rand.Read(nb[:])
	nonce := hex.EncodeToString(nb[:])
	relayName := r.Host
	if err := writeControl(ctx, conn, Control{T: "challenge", Relay: relayName, Nonce: nonce}); err != nil {
		return
	}
	hello, err := readControl(ctx, conn)
	if err != nil || hello.T != "hello" || (hello.Role != "host" && hello.Role != "guest") {
		writeControl(ctx, conn, Control{T: "error", Code: CodeBadHello, Message: "expected hello"})
		return
	}
	pub, err := transport.ParsePeerID(hello.Key)
	sig, serr := base64.StdEncoding.DecodeString(hello.Sig)
	if err != nil || serr != nil || !ed25519.Verify(pub, helloText(relayName, nonce, hello.Role), sig) {
		writeControl(ctx, conn, Control{T: "error", Code: CodeBadHello, Message: "the signature does not match the key"})
		return
	}
	writeControl(ctx, conn, Control{T: "ok"})

	if hello.Role == "host" {
		s.serveHost(ctx, conn, hello.Key)
	} else {
		s.serveGuest(ctx, conn, hello.Key, clientIP(r))
	}
}

func clientIP(r *http.Request) string {
	if f := r.Header.Get("X-Forwarded-For"); f != "" {
		return f
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

// --- host side ---

func (s *Server) serveHost(ctx context.Context, conn *websocket.Conn, key string) {
	h := &hostConn{key: key, conn: conn, sessions: map[string]*relaySession{}}
	s.mu.Lock()
	if old, ok := s.hosts[key]; ok {
		old.conn.Close(websocket.StatusGoingAway, "replaced by a new connection for this key")
	}
	s.hosts[key] = h
	s.mu.Unlock()
	log.Printf("[relay] host %s…%s registered", key[:6], key[len(key)-4:])
	defer func() {
		s.mu.Lock()
		if s.hosts[key] == h {
			delete(s.hosts, key)
		}
		sessions := make([]*relaySession, 0, len(h.sessions))
		for _, rs := range h.sessions {
			sessions = append(sessions, rs)
		}
		s.mu.Unlock()
		for _, rs := range sessions {
			s.endSession(rs, "the host went away")
		}
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
			sid := hex.EncodeToString(b[:16])
			s.mu.Lock()
			rs := h.sessions[sid]
			s.mu.Unlock()
			if rs == nil {
				continue
			}
			rs.last.Store(time.Now().UnixNano())
			if err := rs.writeGuest(ctx, websocket.MessageBinary, b[16:]); err != nil {
				s.endSession(rs, "")
			}
			continue
		}
		var m Control
		if json.Unmarshal(b, &m) != nil {
			continue
		}
		s.mu.Lock()
		rs := h.sessions[m.SID]
		s.mu.Unlock()
		if rs == nil {
			continue
		}
		switch m.T {
		case "accept":
			select {
			case rs.accepted <- true:
			default:
			}
		case "refuse":
			select {
			case rs.accepted <- false:
			default:
			}
		case "close":
			s.endSession(rs, "")
		}
	}
}

// --- guest side ---

func allow(times []time.Time, limit int, now time.Time) ([]time.Time, bool) {
	cut := now.Add(-time.Minute)
	i := 0
	for i < len(times) && times[i].Before(cut) {
		i++
	}
	times = times[i:]
	if len(times) >= limit {
		return times, false
	}
	return append(times, now), true
}

func (s *Server) serveGuest(ctx context.Context, conn *websocket.Conn, key, ip string) {
	open, err := readControl(ctx, conn)
	if err != nil || open.T != "open" {
		return
	}
	now := time.Now()
	s.mu.Lock()
	var okIP, okTo bool
	s.opensIP[ip], okIP = allow(s.opensIP[ip], s.limits.OpensPerIPMin, now)
	s.opensTo[open.To], okTo = allow(s.opensTo[open.To], s.limits.OpensPerHostMin, now)
	h := s.hosts[open.To]
	var refusal *Control
	switch {
	case !okIP || !okTo:
		refusal = &Control{T: "error", Code: CodeRateLimited, Message: "too many session requests; wait a minute"}
	case h == nil:
		refusal = &Control{T: "error", Code: CodeHostOffline, Message: "that instance is not connected to this relay"}
	case len(h.sessions) >= s.limits.SessionsPerHost:
		refusal = &Control{T: "error", Code: CodeLimit, Message: "that instance has as many sessions as this relay allows"}
	case s.perKey[key] >= s.limits.SessionsPerKey:
		refusal = &Control{T: "error", Code: CodeLimit, Message: "you have as many open sessions as this relay allows"}
	}
	var rs *relaySession
	if refusal == nil {
		sid := make([]byte, 16)
		rand.Read(sid)
		rs = &relaySession{sid: hex.EncodeToString(sid), sidBytes: sid, host: h, guest: conn,
			guestKey: key, accepted: make(chan bool, 1)}
		rs.last.Store(now.UnixNano())
		h.sessions[rs.sid] = rs
		s.sessions[rs.sid] = rs
		s.perKey[key]++
	}
	s.mu.Unlock()
	if refusal != nil {
		writeControl(ctx, conn, *refusal)
		return
	}
	defer s.endSession(rs, "")

	b, _ := json.Marshal(Control{T: "incoming", SID: rs.sid, From: key})
	if h.write(ctx, websocket.MessageText, b) != nil {
		writeControl(ctx, conn, Control{T: "error", Code: CodeHostOffline, Message: "the host went away"})
		return
	}
	select {
	case ok := <-rs.accepted:
		if !ok {
			writeControl(ctx, conn, Control{T: "error", Code: CodeRefused, Message: "the host refused the session"})
			return
		}
	case <-time.After(s.limits.AcceptTimeout):
		writeControl(ctx, conn, Control{T: "error", Code: CodeHostOffline, Message: "the host did not answer"})
		return
	case <-ctx.Done():
		return
	}
	if err := rs.writeGuest(ctx, websocket.MessageText, mustJSON(Control{T: "opened", SID: rs.sid})); err != nil {
		return
	}

	idle := time.NewTicker(time.Second * 15)
	defer idle.Stop()
	readErr := make(chan struct{})
	go func() {
		defer close(readErr)
		for {
			typ, frame, err := conn.Read(ctx)
			if err != nil {
				return
			}
			if typ != websocket.MessageBinary {
				continue // a guest's only control message after opening is closing, which is the socket
			}
			rs.last.Store(time.Now().UnixNano())
			out := append(append(make([]byte, 0, len(frame)+16), rs.sidBytes...), frame...)
			if h.write(ctx, websocket.MessageBinary, out) != nil {
				return
			}
		}
	}()
	for {
		select {
		case <-readErr:
			return
		case <-idle.C:
			if time.Since(time.Unix(0, rs.last.Load())) > s.limits.Idle {
				return
			}
		}
	}
}

func mustJSON(m Control) []byte {
	b, _ := json.Marshal(m)
	return b
}

// endSession removes a session and tells both ends. Idempotent.
func (s *Server) endSession(rs *relaySession, why string) {
	s.mu.Lock()
	if _, ok := s.sessions[rs.sid]; !ok {
		s.mu.Unlock()
		return
	}
	delete(s.sessions, rs.sid)
	delete(rs.host.sessions, rs.sid)
	s.perKey[rs.guestKey]--
	if s.perKey[rs.guestKey] <= 0 {
		delete(s.perKey, rs.guestKey)
	}
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	rs.host.write(ctx, websocket.MessageText, mustJSON(Control{T: "close", SID: rs.sid}))
	if why == "" {
		why = "session closed"
	}
	rs.guest.Close(websocket.StatusNormalClosure, why)
}
