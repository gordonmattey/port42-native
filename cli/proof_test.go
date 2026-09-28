package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// listener serves /proof, signing with key, and returns its port.
func listener(t *testing.T, key ed25519.PrivateKey, peer string) int {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/proof" || key == nil {
			http.NotFound(w, r)
			return
		}
		sig := ed25519.Sign(key, []byte(proofDomain+r.URL.Query().Get("nonce")))
		json.NewEncoder(w).Encode(map[string]string{"peer": peer, "sig": base64.StdEncoding.EncodeToString(sig)})
	}))
	t.Cleanup(srv.Close)
	u, _ := url.Parse(srv.URL)
	port, _ := strconv.Atoi(u.Port())
	return port
}

func instanceDir(t *testing.T, peer string) string {
	t.Helper()
	dir := t.TempDir()
	if peer != "" {
		if err := os.WriteFile(filepath.Join(dir, "gateway-peer"), []byte(peer), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// The CLI sends its token only to the gateway that proves it holds this instance's key (CLI-03).
// Whatever got the port first, while Port42 was down or restarting, used to receive it.
func TestTheCLIChecksTheListenerBeforeSendingItsToken(t *testing.T) {
	_, ours, _ := ed25519.GenerateKey(nil)
	_, theirs, _ := ed25519.GenerateKey(nil)
	ourPeer := peerIDEncoding.EncodeToString(ours.Public().(ed25519.PublicKey))
	theirPeer := peerIDEncoding.EncodeToString(theirs.Public().(ed25519.PublicKey))
	dir := instanceDir(t, ourPeer)

	if err := verifyListener(listener(t, ours, ourPeer), dir); err != nil {
		t.Fatalf("our own gateway was refused: %v", err)
	}
	if verifyListener(listener(t, theirs, theirPeer), dir) == nil {
		t.Fatal("a listener holding another key was trusted")
	}
	if verifyListener(listener(t, theirs, ourPeer), dir) == nil {
		t.Fatal("a listener claiming our peer id without our key was trusted")
	}
	if verifyListener(listener(t, nil, ""), dir) == nil {
		t.Fatal("a listener that cannot prove anything was trusted")
	}
	// Nothing recorded to check against: the call goes ahead, as before.
	if err := verifyListener(listener(t, nil, ""), instanceDir(t, "")); err != nil {
		t.Fatalf("with no gateway-peer recorded the call was refused: %v", err)
	}
}
