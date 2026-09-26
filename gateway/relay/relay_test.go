package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/flynn/noise"
	"nhooyr.io/websocket"

	"github.com/port42/gateway/transport"
)

func newKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, k, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func idOf(k ed25519.PrivateKey) string { return transport.PeerID(k.Public().(ed25519.PublicKey)) }

// pipe is two frames endpoints joined in memory; mangle, when set, alters frames from a to b.
type pipeEnd struct {
	in, out chan []byte
	done    chan struct{}
	once    *sync.Once
	mangle  func([]byte) []byte
}

func pipe() (*pipeEnd, *pipeEnd) {
	ab, ba := make(chan []byte, 256), make(chan []byte, 256)
	done, once := make(chan struct{}), &sync.Once{}
	return &pipeEnd{in: ba, out: ab, done: done, once: once}, &pipeEnd{in: ab, out: ba, done: done, once: once}
}

func (p *pipeEnd) SendFrame(ctx context.Context, b []byte) error {
	b = append([]byte(nil), b...)
	if p.mangle != nil {
		b = p.mangle(b)
	}
	select {
	case p.out <- b:
		return nil
	case <-p.done:
		return errors.New("closed")
	}
}

func (p *pipeEnd) RecvFrame(ctx context.Context) ([]byte, error) {
	select {
	case b := <-p.in:
		return b, nil
	case <-p.done:
		return nil, errors.New("closed")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (p *pipeEnd) Close() error { p.once.Do(func() { close(p.done) }); return nil }

func handshake(t *testing.T, guest, host ed25519.PrivateKey, dialled string, a, b *pipeEnd) (transport.Session, transport.Session, error, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var hs transport.Session
	var herr error
	done := make(chan struct{})
	go func() { hs, herr = Respond(ctx, b, host); close(done) }()
	gs, gerr := Initiate(ctx, a, guest, dialled)
	if gerr != nil {
		a.Close()
	}
	<-done
	return gs, hs, gerr, herr
}

func TestTheNoiseKeyIsTheEd25519KeyInMontgomeryForm(t *testing.T) {
	k := newKey(t)
	dh, err := NoiseKey(k)
	if err != nil {
		t.Fatal(err)
	}
	mont, err := MontgomeryPublic(k.Public().(ed25519.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(dh.Public, mont) {
		t.Fatalf("the X25519 key from the seed and the one from the public key disagree")
	}
}

func TestBothEndsAreAuthenticatedAndLargeMessagesArrive(t *testing.T) {
	guest, host := newKey(t), newKey(t)
	a, b := pipe()
	gs, hs, gerr, herr := handshake(t, guest, host, idOf(host), a, b)
	if gerr != nil || herr != nil {
		t.Fatalf("handshake: %v / %v", gerr, herr)
	}
	if hs.RemotePeer() != idOf(guest) || gs.RemotePeer() != idOf(host) {
		t.Fatalf("each end must know the other by its key: %q %q", hs.RemotePeer(), gs.RemotePeer())
	}
	ctx := context.Background()
	big := bytes.Repeat([]byte("x"), 3<<20)
	go gs.Send(ctx, big)
	got, err := hs.Recv(ctx)
	if err != nil || !bytes.Equal(got, big) {
		t.Fatalf("a 3 MB message did not arrive whole: %v", err)
	}
	hs.Send(ctx, []byte("reply"))
	if r, _ := gs.Recv(ctx); string(r) != "reply" {
		t.Fatalf("reply %q", r)
	}
}

func TestACallerThatDialsTheWrongKeyReachesNobody(t *testing.T) {
	guest, host, someoneElse := newKey(t), newKey(t), newKey(t)
	a, b := pipe()
	_, _, gerr, herr := handshake(t, guest, host, idOf(someoneElse), a, b)
	if gerr == nil || herr == nil {
		t.Fatalf("a handshake meant for another key completed: %v / %v", gerr, herr)
	}
}

func TestACallerCannotClaimSomeoneElsesIdentity(t *testing.T) {
	host, liar, victim := newKey(t), newKey(t), newKey(t)
	a, b := pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	errc := make(chan error, 1)
	go func() { _, err := Respond(ctx, b, host); errc <- err }()
	// The liar completes Noise with its own static key but names the victim's Ed25519 key.
	hostStatic, _ := MontgomeryPublic(host.Public().(ed25519.PublicKey))
	liarDH, _ := NoiseKey(liar)
	hs, _ := noise.NewHandshakeState(noise.Config{CipherSuite: suite, Pattern: noise.HandshakeIK,
		Initiator: true, Prologue: prologue, StaticKeypair: liarDH, PeerStatic: hostStatic})
	msg1, _, _, _ := hs.WriteMessage(nil, victim.Public().(ed25519.PublicKey))
	a.SendFrame(ctx, msg1)
	if err := <-errc; err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("the host accepted a caller naming someone else's key: %v", err)
	}
}

func TestAnAlteredFrameEndsTheSession(t *testing.T) {
	guest, host := newKey(t), newKey(t)
	a, b := pipe()
	gs, hs, gerr, herr := handshake(t, guest, host, idOf(host), a, b)
	if gerr != nil || herr != nil {
		t.Fatalf("handshake: %v / %v", gerr, herr)
	}
	a.mangle = func(f []byte) []byte { f[len(f)/2] ^= 1; return f } // the relay flips one bit
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	gs.Send(ctx, []byte(`{"type":"call","method":"port.update"}`))
	if msg, err := hs.Recv(ctx); err == nil || !strings.Contains(err.Error(), "authenticate") {
		t.Fatalf("an altered frame was not refused as unauthentic: %q %v", msg, err)
	}
}

func TestAClientRefusesARelayThatNamesItselfSomethingElse(t *testing.T) {
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		writeControl(r.Context(), c, Control{T: "challenge", Relay: "relay1.port42.ai", Nonce: "n"})
		c.Read(r.Context())
	}))
	defer fake.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, err := connect(ctx, "ws"+strings.TrimPrefix(fake.URL, "http")+"/v1", newKey(t), "host")
	if err == nil || !strings.Contains(err.Error(), "calls itself") {
		t.Fatalf("signed a challenge for a relay other than the one dialled: %v", err)
	}
}

// --- the relay server ---

type relayWorld struct {
	srv   *httptest.Server
	url   string
	host  *Transport
	guest *Transport
	ctx   context.Context
}

func newRelayWorld(t *testing.T, l Limits) relayWorld {
	t.Helper()
	srv := httptest.NewServer(NewServer(l).Handler())
	t.Cleanup(srv.Close)
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	host := NewTransport(newKey(t), []string{url})
	host.Run(ctx)
	return relayWorld{srv: srv, url: url, host: host, guest: NewTransport(newKey(t), []string{url}), ctx: ctx}
}

func (w relayWorld) dialWhenRegistered(t *testing.T) (transport.Session, error) {
	t.Helper()
	var s transport.Session
	var err error
	for i := 0; i < 50; i++ {
		if s, err = w.guest.Dial(w.ctx, w.host.PeerID()); err == nil {
			return s, nil
		}
		var r *Refusal
		if !errors.As(err, &r) || r.Code != CodeHostOffline {
			return nil, err
		}
		time.Sleep(20 * time.Millisecond) // the host is still registering
	}
	return nil, err
}

func TestTheRelayPairsAGuestWithTheHostItNames(t *testing.T) {
	w := newRelayWorld(t, DefaultLimits)
	gs, err := w.dialWhenRegistered(t)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	hs, err := w.host.Accept(w.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if hs.RemotePeer() != w.guest.PeerID() {
		t.Fatalf("the host sees %q, want the guest's key", hs.RemotePeer())
	}
	gs.Send(w.ctx, []byte("hello host"))
	if m, _ := hs.Recv(w.ctx); string(m) != "hello host" {
		t.Fatalf("got %q", m)
	}
	hs.Send(w.ctx, []byte("hello guest"))
	if m, _ := gs.Recv(w.ctx); string(m) != "hello guest" {
		t.Fatalf("got %q", m)
	}
}

func TestAKeyNobodyRegisteredIsOffline(t *testing.T) {
	w := newRelayWorld(t, DefaultLimits)
	_, err := w.guest.Dial(w.ctx, idOf(newKey(t)))
	var r *Refusal
	if !errors.As(err, &r) || r.Code != CodeHostOffline {
		t.Fatalf("got %v, want host_offline", err)
	}
}

func TestNobodyRegistersAKeyTheyDoNotHold(t *testing.T) {
	w := newRelayWorld(t, DefaultLimits)
	conn, _, err := websocket.Dial(w.ctx, w.url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	ch, _ := readControl(w.ctx, conn)
	// Sign with one key, claim another: the victim's.
	victim, signer := newKey(t), newKey(t)
	sig := ed25519.Sign(signer, helloText(ch.Relay, ch.Nonce, "host"))
	writeControl(w.ctx, conn, Control{T: "hello", Role: "host", Key: idOf(victim),
		Sig: base64.StdEncoding.EncodeToString(sig)})
	if m, _ := readControl(w.ctx, conn); m.T != "error" || m.Code != CodeBadHello {
		t.Fatalf("a host claim signed by another key was accepted: %+v", m)
	}
}

func TestASignatureForAnotherRelayIsRefused(t *testing.T) {
	w := newRelayWorld(t, DefaultLimits)
	conn, _, err := websocket.Dial(w.ctx, w.url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	ch, _ := readControl(w.ctx, conn)
	k := newKey(t)
	sig := ed25519.Sign(k, helloText("relay2.example", ch.Nonce, "host"))
	writeControl(w.ctx, conn, Control{T: "hello", Role: "host", Key: idOf(k), Sig: base64.StdEncoding.EncodeToString(sig)})
	if m, _ := readControl(w.ctx, conn); m.T != "error" {
		t.Fatalf("a hello signed for another relay was accepted: %+v", m)
	}
}

func TestAGuestIsLimitedToItsShareOfSessions(t *testing.T) {
	l := DefaultLimits
	l.SessionsPerKey = 1
	w := newRelayWorld(t, l)
	if _, err := w.dialWhenRegistered(t); err != nil {
		t.Fatalf("first: %v", err)
	}
	_, err := w.guest.Dial(w.ctx, w.host.PeerID())
	var r *Refusal
	if !errors.As(err, &r) || r.Code != CodeLimit {
		t.Fatalf("a second session past the limit: %v", err)
	}
}
