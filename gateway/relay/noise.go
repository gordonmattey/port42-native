// Package relay is the relay-first transport (nautilus Phase 4, step 4.4; docs/design-phase4-relay.md):
// a small server that pairs two instances' keys and forwards bytes, and the client that reaches
// another instance through it with Noise IK end to end, so the relay carries ciphertext it cannot read
// or forge.
package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha512"
	"errors"
	"fmt"
	"sync"

	"filippo.io/edwards25519"
	"github.com/flynn/noise"
	"golang.org/x/crypto/curve25519"

	"github.com/port42/gateway/transport"
)

// Noise_IK_25519_ChaChaPoly_SHA256. IK because the caller already knows the host's key (from the
// invite or the address): one round trip, both sides authenticated, forward secrecy, and the caller's
// identity travels encrypted.
var suite = noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashSHA256)

// prologue binds both ends to this protocol. v1 is what instances speak to each other and what a
// guest holding its seed speaks; v2 is a guest whose keys the page cannot read (GST-02,
// docs/design-gst02-guest-keys.md).
var prologue = []byte("port42-noise-v1")
var prologueV2 = []byte("port42-noise-v2")

// v2Payload is a v2 guest's message-1 payload: its Ed25519 public key, then that key's signature
// over V2Binding.
const v2Payload = ed25519.PublicKeySize + ed25519.SignatureSize

// V2Binding is what a v2 guest signs with its Ed25519 identity key: that its separate X25519 static
// key speaks for it, to this host, in this handshake (the ephemeral key makes a signature useless in
// any other session). The guest page builds the same bytes (guest/src/noise.js).
func V2Binding(host string, ephemeral, static []byte) []byte {
	b := append([]byte("port42-noise-v2 static|"), host...)
	b = append(b, ephemeral...)
	return append(b, static...)
}

// maxNoiseMessage is Noise's limit; a frame's plaintext leaves room for the 16-byte tag.
const (
	maxNoiseMessage = 65535
	maxPlainFrame   = maxNoiseMessage - 16
)

// NoiseKey is the X25519 key an instance's Ed25519 key converts to: the private scalar is the first
// half of SHA-512 of the seed (as Ed25519 itself derives it), and the public key is the same point in
// Montgomery form. So an instance has ONE identity, and a peer proves its peer id by completing the
// handshake with the static key that converts from it.
func NoiseKey(priv ed25519.PrivateKey) (noise.DHKey, error) {
	h := sha512.Sum512(priv.Seed())
	scalar := h[:32]
	pub, err := curve25519.X25519(scalar, curve25519.Basepoint)
	if err != nil {
		return noise.DHKey{}, err
	}
	return noise.DHKey{Private: append([]byte(nil), scalar...), Public: pub}, nil
}

// MontgomeryPublic converts an Ed25519 public key to the X25519 public key it corresponds to.
func MontgomeryPublic(pub ed25519.PublicKey) ([]byte, error) {
	p, err := new(edwards25519.Point).SetBytes(pub)
	if err != nil {
		return nil, err
	}
	return p.BytesMontgomery(), nil
}

// frames is what the handshake and the session run over: one relay stream, frame by frame.
type frames interface {
	SendFrame(ctx context.Context, b []byte) error
	RecvFrame(ctx context.Context) ([]byte, error)
	Close() error
}

// Initiate runs the caller's side: it knows the host's peer id and proves its own.
func Initiate(ctx context.Context, f frames, me ed25519.PrivateKey, host string) (transport.Session, error) {
	hostPub, err := transport.ParsePeerID(host)
	if err != nil {
		return nil, err
	}
	hostStatic, err := MontgomeryPublic(hostPub)
	if err != nil {
		return nil, err
	}
	key, err := NoiseKey(me)
	if err != nil {
		return nil, err
	}
	hs, err := noise.NewHandshakeState(noise.Config{CipherSuite: suite, Pattern: noise.HandshakeIK,
		Initiator: true, Prologue: prologue, StaticKeypair: key, PeerStatic: hostStatic})
	if err != nil {
		return nil, err
	}
	msg1, _, _, err := hs.WriteMessage(nil, me.Public().(ed25519.PublicKey))
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
		return nil, fmt.Errorf("the host did not prove its key: %w", err)
	}
	return newSession(f, host, send, recv), nil
}

// readFirst reads message 1 under one prologue. Noise fixes the prologue before anything is read, so
// the responder tries v2, then v1, on the same bytes: a message written under the other prologue
// fails to decrypt, and nothing about the framing changes.
func readFirst(pro []byte, key noise.DHKey, msg1 []byte) (*noise.HandshakeState, []byte, error) {
	hs, err := noise.NewHandshakeState(noise.Config{CipherSuite: suite, Pattern: noise.HandshakeIK,
		Initiator: false, Prologue: pro, StaticKeypair: key})
	if err != nil {
		return nil, nil, err
	}
	claimed, _, _, err := hs.ReadMessage(nil, msg1)
	return hs, claimed, err
}

// Respond runs the host's side and returns the session with the caller's authenticated peer id.
func Respond(ctx context.Context, f frames, me ed25519.PrivateKey) (transport.Session, error) {
	key, err := NoiseKey(me)
	if err != nil {
		return nil, err
	}
	msg1, err := f.RecvFrame(ctx)
	if err != nil {
		return nil, err
	}
	var id ed25519.PublicKey
	hs, claimed, err := readFirst(prologueV2, key, msg1)
	if err == nil {
		// v2 (GST-02): the caller's Ed25519 key signed that its X25519 static key speaks for it, to
		// this host, in this handshake. The handshake proved it holds that X25519 key.
		if len(claimed) != v2Payload {
			return nil, errors.New("handshake: no identity")
		}
		id = ed25519.PublicKey(claimed[:ed25519.PublicKeySize])
		binding := V2Binding(transport.PeerID(me.Public().(ed25519.PublicKey)), hs.PeerEphemeral(), hs.PeerStatic())
		if !ed25519.Verify(id, binding, claimed[ed25519.PublicKeySize:]) {
			return nil, errors.New("handshake: the caller's key did not sign for this session")
		}
	} else {
		if hs, claimed, err = readFirst(prologue, key, msg1); err != nil {
			return nil, fmt.Errorf("handshake: %w", err)
		}
		// v1: the caller names its Ed25519 key; the handshake proved it holds the X25519 key in
		// PeerStatic. They must be the same identity, or it is naming someone else.
		if len(claimed) != ed25519.PublicKeySize {
			return nil, errors.New("handshake: no identity")
		}
		want, err := MontgomeryPublic(ed25519.PublicKey(claimed))
		if err != nil || !bytes.Equal(want, hs.PeerStatic()) {
			return nil, errors.New("handshake: the caller's key does not match the identity it claims")
		}
		id = ed25519.PublicKey(claimed)
	}
	msg2, recv, send, err := hs.WriteMessage(nil, nil)
	if err != nil {
		return nil, err
	}
	if err := f.SendFrame(ctx, msg2); err != nil {
		return nil, err
	}
	return newSession(f, transport.PeerID(id), send, recv), nil
}

// session is a transport.Session over Noise: each message is split into frames, each frame encrypted.
type session struct {
	f      frames
	remote string
	sendMu sync.Mutex
	send   *noise.CipherState
	recvMu sync.Mutex
	recv   *noise.CipherState
	asm    *transport.Reassembler
}

func newSession(f frames, remote string, send, recv *noise.CipherState) *session {
	return &session{f: f, remote: remote, send: send, recv: recv,
		asm: transport.NewReassembler(transport.MaxMessage)}
}

func (s *session) RemotePeer() string { return s.remote }
func (s *session) Close() error       { return s.f.Close() }

func (s *session) Send(ctx context.Context, msg []byte) error {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	for _, plain := range transport.SplitMessage(msg, maxPlainFrame) {
		sealed, err := s.send.Encrypt(nil, nil, plain)
		if err != nil {
			return err
		}
		if err := s.f.SendFrame(ctx, sealed); err != nil {
			return err
		}
	}
	return nil
}

func (s *session) Recv(ctx context.Context) ([]byte, error) {
	s.recvMu.Lock()
	defer s.recvMu.Unlock()
	for {
		sealed, err := s.f.RecvFrame(ctx)
		if err != nil {
			return nil, err
		}
		plain, err := s.recv.Decrypt(nil, nil, sealed)
		if err != nil {
			// A frame that does not authenticate was altered or forged: the session is over.
			s.f.Close()
			return nil, fmt.Errorf("a frame failed to authenticate: %w", err)
		}
		msg, err := s.asm.Add(plain)
		if err != nil {
			s.f.Close()
			return nil, err
		}
		if msg != nil {
			return msg, nil
		}
	}
}
