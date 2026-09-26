package transport

import (
	"context"
	"errors"
	"sync"
)

// THE TRANSPORT SEAM (nautilus Phase 4, step 4.3; docs/design-phase4-relay.md "The gateway").
//
// A remote caller reaches the door through a Transport, and the door sees nothing of how: four verbs,
// the ones plan-shell-only.md names. listen (Accept), dial, peer id, and a stream (a Session). The
// relay with Noise is one implementation (step 4.4); a direct path later is another. The in-memory one
// below is what proves the seam pluggable: the door is tested over it with no network at all.
//
// A Session carries whole messages, each one of the door's JSON envelopes. Splitting a message to fit
// a transport's frame size is the transport's business (chunk.go), not the door's.

// Transport is how remote callers arrive, and how this instance reaches another.
type Transport interface {
	// Accept waits for the next inbound session, whose remote peer the transport has authenticated.
	Accept(ctx context.Context) (Session, error)
	// Dial opens a session to another instance by its peer id.
	Dial(ctx context.Context, peer string) (Session, error)
	// PeerID is this instance's own peer id on the transport.
	PeerID() string
}

// Session is one authenticated, ordered, reliable message stream with one remote peer.
type Session interface {
	// RemotePeer is the peer id the transport authenticated. The door trusts nothing else about who
	// is on the other end.
	RemotePeer() string
	Send(ctx context.Context, msg []byte) error
	Recv(ctx context.Context) ([]byte, error)
	Close() error
}

// ErrNoSuchPeer is what Dial returns for a peer that is not reachable.
var ErrNoSuchPeer = errors.New("no such peer")

// --- The in-memory transport, for tests ---

// MemNetwork connects MemTransports in one process.
type MemNetwork struct {
	mu    sync.Mutex
	nodes map[string]*MemTransport
}

func NewMemNetwork() *MemNetwork { return &MemNetwork{nodes: map[string]*MemTransport{}} }

// MemTransport is one instance on a MemNetwork. Its "authentication" is that the network knows which
// node dialled, which is exactly the property a real transport provides by cryptography.
type MemTransport struct {
	net      *MemNetwork
	peer     string
	incoming chan Session
}

func (n *MemNetwork) Join(peer string) *MemTransport {
	n.mu.Lock()
	defer n.mu.Unlock()
	t := &MemTransport{net: n, peer: peer, incoming: make(chan Session, 16)}
	n.nodes[peer] = t
	return t
}

func (t *MemTransport) PeerID() string { return t.peer }

func (t *MemTransport) Accept(ctx context.Context) (Session, error) {
	select {
	case s := <-t.incoming:
		return s, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (t *MemTransport) Dial(ctx context.Context, peer string) (Session, error) {
	t.net.mu.Lock()
	target, ok := t.net.nodes[peer]
	t.net.mu.Unlock()
	if !ok {
		return nil, ErrNoSuchPeer
	}
	a2b, b2a := make(chan []byte, 64), make(chan []byte, 64)
	done := make(chan struct{})
	var once sync.Once
	closeFn := func() error { once.Do(func() { close(done) }); return nil }
	mine := &memSession{remote: peer, out: a2b, in: b2a, done: done, close: closeFn}
	theirs := &memSession{remote: t.peer, out: b2a, in: a2b, done: done, close: closeFn}
	select {
	case target.incoming <- theirs:
		return mine, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

type memSession struct {
	remote string
	out    chan<- []byte
	in     <-chan []byte
	done   chan struct{}
	close  func() error
}

func (s *memSession) RemotePeer() string { return s.remote }
func (s *memSession) Close() error        { return s.close() }

func (s *memSession) Send(ctx context.Context, msg []byte) error {
	select {
	case s.out <- append([]byte(nil), msg...):
		return nil
	case <-s.done:
		return errors.New("session closed")
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *memSession) Recv(ctx context.Context) ([]byte, error) {
	select {
	case m := <-s.in:
		return m, nil
	case <-s.done:
		return nil, errors.New("session closed")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
