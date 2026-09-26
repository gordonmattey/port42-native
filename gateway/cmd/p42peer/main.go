// p42peer is a test peer for the relay (nautilus Phase 4, 4.4): another "instance" with its own key
// that dials a Port42 by peer id through a relay and makes one call. A harness tool, not a product.
//
//	p42peer -relay wss://relay1.port42.ai/v1 -to <peer id> -method ports.list [-args '{}'] [-key file]
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/port42/gateway/relay"
)

func main() {
	relayURL := flag.String("relay", "wss://relay1.port42.ai/v1", "relay URL")
	to := flag.String("to", "", "the peer id to call")
	method := flag.String("method", "ports.list", "method")
	args := flag.String("args", "{}", "arguments, as JSON")
	keyFile := flag.String("key", os.ExpandEnv("$HOME/.port42/p42peer.key"), "this peer's seed file")
	whoami := flag.Bool("whoami", false, "print this peer's id and exit")
	flag.Parse()

	key := loadKey(*keyFile)
	t := relay.NewTransport(key, []string{*relayURL})
	if *whoami {
		fmt.Println(t.PeerID())
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	start := time.Now()
	s, err := t.Dial(ctx, *to)
	dialed := time.Since(start)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dial:", err)
		os.Exit(1)
	}
	defer s.Close()
	call, _ := json.Marshal(map[string]any{"type": "call", "method": *method, "call_id": "p42peer-1",
		"args": json.RawMessage(*args)})
	if err := s.Send(ctx, call); err != nil {
		fmt.Fprintln(os.Stderr, "send:", err)
		os.Exit(1)
	}
	for {
		b, err := s.Recv(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, "recv:", err)
			os.Exit(1)
		}
		fmt.Println(string(b))
		fmt.Fprintf(os.Stderr, "timing: dial+handshake %v, call round trip %v\n", dialed.Round(time.Millisecond), (time.Since(start) - dialed).Round(time.Millisecond))
		if strings.Contains(string(b), `"type":"response"`) || strings.Contains(string(b), `"type":"error"`) {
			return
		}
	}
}

func loadKey(path string) ed25519.PrivateKey {
	if b, err := os.ReadFile(path); err == nil {
		if seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b))); err == nil && len(seed) == ed25519.SeedSize {
			return ed25519.NewKeyFromSeed(seed)
		}
	}
	seed := make([]byte, ed25519.SeedSize)
	rand.Read(seed)
	os.MkdirAll(strings.TrimSuffix(path, "/"+lastElem(path)), 0o700)
	os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(seed)), 0o600)
	return ed25519.NewKeyFromSeed(seed)
}

func lastElem(p string) string {
	i := strings.LastIndex(p, "/")
	return p[i+1:]
}
