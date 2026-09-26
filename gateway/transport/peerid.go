package transport

import (
	"crypto/ed25519"
	"encoding/base32"
	"errors"
)

// A peer id is the lowercase base32 (no padding) of an Ed25519 public key: 52 characters. Lowercase
// because a URL host is lowercased by many parsers and linkifiers, and the id is the host of
// `port42://<peer>/<portId>`. This is the ONE implementation; the app is told the ids, never computes
// them (nautilus Phase 4, 4.2).

var peerIDEncoding = base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)

// PeerID renders a public key as a peer id.
func PeerID(pub ed25519.PublicKey) string { return peerIDEncoding.EncodeToString(pub) }

// ParsePeerID recovers the public key a peer id names.
func ParsePeerID(id string) (ed25519.PublicKey, error) {
	b, err := peerIDEncoding.DecodeString(id)
	if err != nil || len(b) != ed25519.PublicKeySize {
		return nil, errors.New("not a peer id")
	}
	return ed25519.PublicKey(b), nil
}
