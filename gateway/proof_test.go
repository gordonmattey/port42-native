package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/port42/gateway/transport"
)

// The gateway proves which instance it is by signing a client's nonce with its peer key (CLI-03).
func TestTheGatewayProvesItsIdentity(t *testing.T) {
	g := NewGateway()
	seed := make([]byte, ed25519.SeedSize)
	seed[0] = 7
	g.SetPeerIdentity(PeerIdentity{key: ed25519.NewKeyFromSeed(seed)})

	w := httptest.NewRecorder()
	g.HandleProof(w, httptest.NewRequest(http.MethodGet, "/proof?nonce=0123456789abcdef0123", nil))
	var out struct{ Peer, Sig string }
	if w.Code != http.StatusOK || json.NewDecoder(w.Body).Decode(&out) != nil {
		t.Fatalf("no proof: %d", w.Code)
	}
	pub, err := transport.ParsePeerID(out.Peer)
	if err != nil || out.Peer != g.selfPeerID() {
		t.Fatalf("the proof names %q, want this instance's peer id", out.Peer)
	}
	sig, _ := base64.StdEncoding.DecodeString(out.Sig)
	if !ed25519.Verify(pub, []byte(proofDomain+"0123456789abcdef0123"), sig) {
		t.Fatal("the signature does not verify against the peer id")
	}

	// No identity, or a nonce too short to be fresh: no proof.
	w = httptest.NewRecorder()
	NewGateway().HandleProof(w, httptest.NewRequest(http.MethodGet, "/proof?nonce=0123456789abcdef0123", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("a gateway with no identity answered %d", w.Code)
	}
	w = httptest.NewRecorder()
	g.HandleProof(w, httptest.NewRequest(http.MethodGet, "/proof?nonce=short", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("a short nonce was signed: %d", w.Code)
	}
}
