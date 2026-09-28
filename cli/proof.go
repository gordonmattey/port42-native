package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The gateway's peer id encoding (gateway/transport/peerid.go), repeated because the CLI is its own module.
var peerIDEncoding = base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)

const proofDomain = "port42-gateway-proof-v1|"

// instanceDirForPort is the ~/.port42/<instance> directory whose gateway-port names port, or "".
func instanceDirForPort(port int) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	dirs, _ := filepath.Glob(filepath.Join(home, ".port42", "*"))
	for _, dir := range dirs {
		if b, err := os.ReadFile(filepath.Join(dir, "gateway-port")); err == nil && strings.TrimSpace(string(b)) == fmt.Sprint(port) {
			return dir
		}
	}
	return ""
}

// verifyListener checks that what listens on port is this instance's gateway before a token is sent
// to it (CLI-03). Any process that got the port first, while Port42 was down or restarting, used to
// receive the token. The app records the gateway's peer id in gateway-peer; the gateway signs a fresh
// nonce with that key. With no gateway-peer recorded (an app from before this, or an instance with no
// identity) there is nothing to check against, and the call goes ahead as before.
func verifyListener(port int, dir string) error {
	if dir == "" {
		return nil
	}
	recorded, err := os.ReadFile(filepath.Join(dir, "gateway-peer"))
	if err != nil {
		return nil
	}
	peer := strings.TrimSpace(string(recorded))
	pub, err := peerIDEncoding.DecodeString(peer)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("%s does not hold a peer id; relaunch Port42 to rewrite it", filepath.Join(dir, "gateway-peer"))
	}
	var n [16]byte
	rand.Read(n[:])
	nonce := hex.EncodeToString(n[:])
	notOurs := fmt.Errorf("the process on port %d is not your Port42's gateway, so your token was not sent to it", port)
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Get(fmt.Sprintf("http://127.0.0.1:%d/proof?nonce=%s", port, nonce))
	if err != nil {
		if strings.Contains(err.Error(), "connection refused") {
			return ErrNotRunning
		}
		return notOurs
	}
	defer resp.Body.Close()
	var out struct{ Peer, Sig string }
	if resp.StatusCode != http.StatusOK || json.NewDecoder(resp.Body).Decode(&out) != nil {
		return notOurs
	}
	sig, err := base64.StdEncoding.DecodeString(out.Sig)
	if err != nil || out.Peer != peer || !ed25519.Verify(ed25519.PublicKey(pub), []byte(proofDomain+nonce), sig) {
		return notOurs
	}
	return nil
}
