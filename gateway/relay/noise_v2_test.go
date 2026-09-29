package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"strings"
	"testing"
	"time"

	"github.com/flynn/noise"

	"github.com/port42/gateway/transport"
)

// GST-02: a v2 guest holds two keys the page cannot read, an Ed25519 identity key and a separate
// X25519 Noise key, and signs that the X25519 key speaks for it, to this host, in this handshake
// (V2Binding). The host's Respond accepts v2 and still accepts v1.

// v2Case says how a test v2 guest builds its payload: which host and which ephemeral it signs, what
// it signs with, and whether the payload is cut short.
type v2Case struct {
	signHost   string             // the host named in the binding; "" means the real one
	signOtherE bool               // sign some other ephemeral key (a replayed signature)
	signer     ed25519.PrivateKey // who signs; nil means the identity key itself
	truncate   bool
}

// initiateV2 is a v2 guest, as the guest page runs it (guest/src/noise.js), written against
// flynn/noise so the Go side can be checked on its own.
func initiateV2(ctx context.Context, f frames, id ed25519.PrivateKey, host string, c v2Case) (transport.Session, error) {
	hostPub, err := transport.ParsePeerID(host)
	if err != nil {
		return nil, err
	}
	hostStatic, _ := MontgomeryPublic(hostPub)
	static, _ := noise.DH25519.GenerateKeypair(rand.Reader)
	// The ephemeral key must be known before message 1 is written, because the guest signs it.
	// flynn/noise always draws the ephemeral from its random source, so hand it the one to use.
	ephPriv := make([]byte, 32)
	rand.Read(ephPriv)
	eph, _ := noise.DH25519.GenerateKeypair(bytes.NewReader(ephPriv))
	hs, err := noise.NewHandshakeState(noise.Config{CipherSuite: suite, Pattern: noise.HandshakeIK,
		Initiator: true, Prologue: prologueV2, StaticKeypair: static, PeerStatic: hostStatic,
		Random: bytes.NewReader(ephPriv)})
	if err != nil {
		return nil, err
	}
	signedHost, signedE, signer := host, eph.Public, id
	if c.signHost != "" {
		signedHost = c.signHost
	}
	if c.signOtherE {
		other, _ := noise.DH25519.GenerateKeypair(rand.Reader)
		signedE = other.Public
	}
	if c.signer != nil {
		signer = c.signer
	}
	payload := append(append([]byte(nil), id.Public().(ed25519.PublicKey)...),
		ed25519.Sign(signer, V2Binding(signedHost, signedE, static.Public))...)
	if c.truncate {
		payload = payload[:len(payload)-1]
	}
	msg1, _, _, err := hs.WriteMessage(nil, payload)
	if err != nil {
		return nil, err
	}
	if err := f.SendFrame(ctx, msg1); err != nil {
		return nil, err
	}
	msg2, err := f.RecvFrame(ctx)
	if err != nil {
		return nil, err
	}
	_, send, recv, err := hs.ReadMessage(nil, msg2)
	if err != nil {
		return nil, err
	}
	return newSession(f, host, send, recv), nil
}

func handshakeV2(t *testing.T, guest, host ed25519.PrivateKey, c v2Case) (transport.Session, transport.Session, error, error) {
	t.Helper()
	a, b := pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var hs transport.Session
	var herr error
	done := make(chan struct{})
	go func() {
		hs, herr = Respond(ctx, b, host)
		if herr != nil {
			b.Close() // as the host's transport does: a refused handshake ends the stream
		}
		close(done)
	}()
	gs, gerr := initiateV2(ctx, a, guest, idOf(host), c)
	if gerr != nil {
		a.Close()
	}
	<-done
	return gs, hs, gerr, herr
}

func TestAV2GuestIsAcceptedAsItsEd25519Identity(t *testing.T) {
	guest, host := newKey(t), newKey(t)
	gs, hs, gerr, herr := handshakeV2(t, guest, host, v2Case{})
	if gerr != nil || herr != nil {
		t.Fatalf("a v2 guest was refused: %v / %v", gerr, herr)
	}
	if hs.RemotePeer() != idOf(guest) {
		t.Fatalf("the host saw %s, not the guest's peer id %s", hs.RemotePeer(), idOf(guest))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	go gs.Send(ctx, []byte("hello over v2"))
	if got, err := hs.Recv(ctx); err != nil || string(got) != "hello over v2" {
		t.Fatalf("the v2 session does not carry messages: %q %v", got, err)
	}
}

func TestAV1GuestIsStillAccepted(t *testing.T) {
	guest, host := newKey(t), newKey(t)
	a, b := pipe()
	_, hs, gerr, herr := handshake(t, guest, host, idOf(host), a, b)
	if gerr != nil || herr != nil || hs.RemotePeer() != idOf(guest) {
		t.Fatalf("the host stopped accepting v1: %v / %v", gerr, herr)
	}
}

func TestAV2GuestIsRefusedWhenItsSignatureDoesNotHold(t *testing.T) {
	stranger, otherHost := newKey(t), newKey(t)
	for name, c := range map[string]v2Case{
		"a signature by another key":         {signer: stranger},
		"a signature over another ephemeral": {signOtherE: true},
		"a signature naming another host":    {signHost: idOf(otherHost)},
		"a payload cut short":                {truncate: true},
	} {
		t.Run(name, func(t *testing.T) {
			_, _, _, herr := handshakeV2(t, newKey(t), newKey(t), c)
			if herr == nil {
				t.Fatalf("the host accepted %s", name)
			}
			if !strings.Contains(herr.Error(), "did not sign") && !strings.Contains(herr.Error(), "no identity") {
				t.Fatalf("refused for the wrong reason: %v", herr)
			}
		})
	}
}

func TestV2BindingIsTheBytesThePageSigns(t *testing.T) {
	// Pinned so the guest page (guest/src/noise.js, v2Binding) and the host cannot drift apart.
	e, s := make([]byte, 32), make([]byte, 32)
	for i := range e {
		e[i], s[i] = 1, 2
	}
	b := V2Binding("HOST", e, s)
	if !strings.HasPrefix(string(b), "port42-noise-v2 static|HOST") || len(b) != len("port42-noise-v2 static|HOST")+64 {
		t.Fatalf("the binding changed shape: %q", b)
	}
}
