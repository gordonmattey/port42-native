package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
)

// proofDomain separates a listener proof from anything else this key signs.
const proofDomain = "port42-gateway-proof-v1|"

// HandleProof lets a local client check that the process on this port is its Port42's gateway before
// it sends a credential (CLI-03). The client sends a fresh nonce and checks the signature against the
// peer id the app wrote to ~/.port42/<instance>/gateway-peer. Something else listening on the port
// does not hold this instance's key, so it cannot answer, and the client keeps its token.
func (g *Gateway) HandleProof(w http.ResponseWriter, r *http.Request) {
	nonce := r.URL.Query().Get("nonce")
	key := g.peerKey()
	if len(nonce) < 16 || len(nonce) > 128 || key == nil {
		http.Error(w, "no proof", http.StatusNotFound)
		return
	}
	sig := ed25519.Sign(key, []byte(proofDomain+nonce))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"peer": g.selfPeerID(), "sig": base64.StdEncoding.EncodeToString(sig)})
}
