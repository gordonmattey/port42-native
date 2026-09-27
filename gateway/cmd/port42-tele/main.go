// port42-tele serves the invite page (nautilus Phase 4, 4.7) at tele.port42.ai:
//
//	port42-tele -dir ./site      # listens on $PORT, default 8080
package main

import (
	"flag"
	"log"
	"net/http"
	"os"

	"github.com/port42/gateway/tele"
)

func main() {
	dir := flag.String("dir", "/site", "the built site: invite.html, frame.html, dist/port42-guest.js")
	flag.Parse()
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("[tele] serving %s on :%s", *dir, port)
	log.Fatal(http.ListenAndServe(":"+port, tele.Handler(*dir)))
}
