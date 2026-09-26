package main

import (
	"bufio"
	"crypto/ed25519"
	"encoding/base64"
	"strings"

	"github.com/port42/gateway/transport"
)

// The instance's peer identity (nautilus Phase 4, step 4.2; docs/design-phase4-relay.md "Identity").
//
// Each Port42 instance has one Ed25519 key. The app keeps its 32-byte seed in the Keychain and hands
// it over on stdin at spawn, as the SECOND line after the host credential, never in the environment
// or the arguments (`ps -E` publishes a same-user process's environment). Its public key is the
// instance's peer id, the `<peer>` in `port42://<peer>/<portId>`.
//
// **The peer id is derived here and nowhere else.** The gateway tells the app its own id in the
// `welcome` it sends the host, so the encoding has one implementation, the same rule that keeps the
// client token format out of this process (credentials.go).

// PeerIdentity is the key this instance speaks for. The zero value means none was handed over (a
// gateway launched by hand), and such a gateway has no peer id.
type PeerIdentity struct {
	key ed25519.PrivateKey
}

// PeerIDFromPublicKey renders a public key as a peer id (transport.PeerID, the one encoding).
func PeerIDFromPublicKey(pub ed25519.PublicKey) string { return transport.PeerID(pub) }

// Key is the instance's private key, for the relay and Noise. nil when none was handed over.
func (p PeerIdentity) Key() ed25519.PrivateKey { return p.key }

// ReadPeerIdentity takes the second handover line, a base64 Ed25519 seed, from the reader
// `ReadHostCredential` returned. A missing or malformed line gives the zero identity rather than an
// error: a gateway with no peer id still serves the local door.
func ReadPeerIdentity(r *bufio.Reader) PeerIdentity {
	line, err := r.ReadString('\n')
	if err != nil && line == "" {
		return PeerIdentity{}
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimRight(line, "\r\n"))
	if err != nil || len(seed) != ed25519.SeedSize {
		return PeerIdentity{}
	}
	return PeerIdentity{key: ed25519.NewKeyFromSeed(seed)}
}

// Configured reports whether this gateway has a peer identity.
func (p PeerIdentity) Configured() bool { return p.key != nil }

// ID is this instance's peer id, or "" when none was handed over.
func (p PeerIdentity) ID() string {
	if p.key == nil {
		return ""
	}
	return PeerIDFromPublicKey(p.key.Public().(ed25519.PublicKey))
}
