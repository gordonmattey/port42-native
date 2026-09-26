// port42-relay is the relay (nautilus Phase 4; docs/design-phase4-relay.md). It pairs instances by
// key and forwards Noise ciphertext between them. It stores nothing. Run your own:
//
//	port42-relay            # listens on $PORT, default 8080, serving /v1 and /health
//
// behind TLS (wss://your-host/v1), and add that URL to Port42's relays.
package main

import (
	"log"
	"net/http"
	"os"

	"github.com/port42/gateway/relay"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("[relay] listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, relay.NewServer(relay.DefaultLimits).Handler()))
}
