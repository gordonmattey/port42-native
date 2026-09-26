// p42peer is a test peer for the relay (nautilus Phase 4): another "instance" with its own key that
// reaches a Port42 through a relay. A harness tool, not a product.
//
//	p42peer -to <peer id> -method ports.list [-args '{}']          one call
//	p42peer -redeem '<invite link>' [-name Ada] [-code 123456]     redeem, then the calls below
//	        [-method port.getHtml -args '{"id":"…"}'] [-subscribe <port id> -for 5s]
//	p42peer -whoami                                                 this peer's id
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
	"path/filepath"
	"strings"
	"time"

	"github.com/port42/gateway/relay"
)

type coupon struct {
	Host   string   `json:"host"`
	Relays []string `json:"relays"`
	Port   string   `json:"port"`
	Nonce  string   `json:"nonce"`
}

func main() {
	relayURL := flag.String("relay", "", "relay URL (default: the invite's relays, else relay1.port42.ai)")
	to := flag.String("to", "", "the peer id to call")
	redeem := flag.String("redeem", "", "an invite link to redeem first")
	name := flag.String("name", "p42peer", "the name to redeem under")
	code := flag.String("code", "", "the invite's code, if it needs one")
	method := flag.String("method", "", "a method to call")
	args := flag.String("args", "{}", "its arguments, as JSON")
	subscribe := flag.String("subscribe", "", "a port id to subscribe to")
	forDur := flag.Duration("for", 5*time.Second, "how long to listen to a subscription")
	keyFile := flag.String("key", os.ExpandEnv("$HOME/.port42/p42peer.key"), "this peer's seed file")
	whoami := flag.Bool("whoami", false, "print this peer's id and exit")
	flag.Parse()

	key := loadKey(*keyFile)
	relays := []string{"wss://relay1.port42.ai/v1"}
	var c coupon
	if *redeem != "" {
		frag := *redeem
		if i := strings.Index(frag, "#"); i >= 0 {
			frag = frag[i+1:]
		}
		raw, err := base64.RawURLEncoding.DecodeString(frag)
		if err != nil || json.Unmarshal(raw, &c) != nil {
			fail("not an invite link")
		}
		*to, relays = c.Host, c.Relays
	}
	if *relayURL != "" {
		relays = []string{*relayURL}
	}
	t := relay.NewTransport(key, relays)
	if *whoami {
		fmt.Println(t.PeerID())
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	start := time.Now()
	s, err := t.Dial(ctx, *to)
	if err != nil {
		fail("dial: " + err.Error())
	}
	defer s.Close()
	fmt.Fprintf(os.Stderr, "dialled %s in %v\n", *to, time.Since(start).Round(time.Millisecond))

	n := 0
	call := func(method string, a any) {
		n++
		id := fmt.Sprintf("p42peer-%d", n)
		b, _ := json.Marshal(map[string]any{"type": "call", "method": method, "call_id": id, "args": a})
		t0 := time.Now()
		if err := s.Send(ctx, b); err != nil {
			fail("send: " + err.Error())
		}
		for {
			msg, err := s.Recv(ctx)
			if err != nil {
				fail("recv: " + err.Error())
			}
			fmt.Printf("%s %s\n", method, msg)
			if strings.Contains(string(msg), `"type":"response"`) || strings.Contains(string(msg), `"type":"error"`) {
				fmt.Fprintf(os.Stderr, "%s took %v\n", method, time.Since(t0).Round(time.Millisecond))
				return
			}
		}
	}
	if *redeem != "" {
		r := map[string]any{"nonce": c.Nonce, "name": *name}
		if *code != "" {
			r["code"] = *code
		}
		call("invite.redeem", r)
	}
	if *method != "" {
		call(*method, json.RawMessage(*args))
	}
	if *subscribe != "" {
		b, _ := json.Marshal(map[string]any{"type": "call", "method": "port.subscribe", "call_id": "sub",
			"args": map[string]string{"id": *subscribe}})
		s.Send(ctx, b)
		lctx, lcancel := context.WithTimeout(ctx, *forDur)
		defer lcancel()
		for {
			msg, err := s.Recv(lctx)
			if err != nil {
				return
			}
			fmt.Printf("subscribe %s\n", msg)
		}
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}

func loadKey(path string) ed25519.PrivateKey {
	if b, err := os.ReadFile(path); err == nil {
		if seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b))); err == nil && len(seed) == ed25519.SeedSize {
			return ed25519.NewKeyFromSeed(seed)
		}
	}
	seed := make([]byte, ed25519.SeedSize)
	rand.Read(seed)
	os.MkdirAll(filepath.Dir(path), 0o700)
	os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(seed)), 0o600)
	return ed25519.NewKeyFromSeed(seed)
}

