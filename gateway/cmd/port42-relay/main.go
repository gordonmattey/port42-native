// port42-relay is the relay (nautilus Phase 4; docs/design-phase4-relay.md). It pairs instances by
// key and forwards Noise ciphertext between them. It stores nothing. Run your own:
//
//	port42-relay            # listens on $PORT, default 8080, serving /v1 and /health
//
// behind TLS (wss://your-host/v1), and add that URL to Port42's relays.
package main

import (
	"log"
	"os"

	"github.com/port42/gateway/relay"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	srv := relay.NewServer(relay.DefaultLimits)
	// Behind Cloudflare (relay1.port42.ai) every connection comes from a Cloudflare address, so the
	// client's own is taken from CF-Connecting-IP. Set PORT42_RELAY_BEHIND_CLOUDFLARE=0 for a relay
	// that is reached directly, where that header would be whatever the client sent (REL-01).
	srv.TrustCloudflare = os.Getenv("PORT42_RELAY_BEHIND_CLOUDFLARE") != "0"
	log.Printf("[relay] listening on :%s (client address from CF-Connecting-IP: %v)", port, srv.TrustCloudflare)
	log.Fatal(relay.NewHTTPServer(":"+port, srv.Handler()).ListenAndServe())
}
