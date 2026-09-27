package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/port42/gateway/relay"
)

// Injected at build time via -ldflags
var posthogAPIKey string

func main() {
	addr := flag.String("addr", ":4242", "listen address")
	watchParent := flag.Bool("watch-parent", false, "exit when stdin (held by the parent app) closes at EOF")
	relays := flag.String("relay", "", "comma-separated relay URLs (wss://host/v1) to register on and serve remote callers through")
	flag.Parse()

	// Log to file for debugging
	home, _ := os.UserHomeDir()
	logPath := home + "/Library/Application Support/Port42/gateway" + *addr + ".log"
	os.MkdirAll(home+"/Library/Application Support/Port42", 0755)
	// KEEP THE LAST RUN'S LOG. This used to open with O_TRUNC, so a gateway that crashed and was
	// restarted wiped the only record of why. The previous run's file is kept as `.1`.
	if _, err := os.Stat(logPath); err == nil {
		os.Rename(logPath, logPath+".1")
	}
	if f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644); err == nil {
		log.SetOutput(f)
	}

	gw := NewGateway()

	mux := newMux(gw)

	srv := &http.Server{
		Addr:    *addr,
		Handler: mux,
		// No read/write timeouts: WebSocket connections are long-lived
		// and timeouts would kill them (especially through a reverse proxy)
	}

	done := make(chan os.Signal, 1)
	signal.Notify(done, os.Interrupt, syscall.SIGTERM)

	// Parent-death watch. The app holds the write end of our stdin and never writes to it. If
	// the app dies by ANY means (normal quit, crash, force-quit / SIGKILL), the kernel closes
	// that end and we hit EOF here. The two cooperative stop paths (the app's willTerminate
	// observer and our own SIGTERM handler) both run cleanup code, so a SIGKILL runs neither and
	// the gateway would orphan on ppid 1 holding the port. This survives SIGKILL because it needs
	// no cleanup on either side — the FD close is the kernel's job. Gated so a manually-run
	// gateway (no pipe) is unaffected.
	if *watchParent {
		// THE CREDENTIAL COMES FIRST, THEN THE DEATH-WATCH, DOWN THE SAME PIPE.
		//
		// Gated on -watch-parent because that flag is what distinguishes an app-spawned gateway from
		// one launched by hand: a hand-launched relay has an interactive stdin, and a blocking read
		// there would hang it. Such a relay gets no credential and so serves channel routing only —
		// it cannot check a host claim, and must not pretend it can.
		//
		// `io.Copy` MUST resume from the reader `ReadHostCredential` returns, not from os.Stdin:
		// anything the buffer already pulled in past the first line would be silently discarded.
		// Spike C's one carried detail, and the reason that reader is returned at all.
		go func() {
			cred, rest := ReadHostCredential(os.Stdin)
			gw.SetHostCredential(cred)
			if cred.Configured() {
				log.Println("[gateway] host credential received") // never the value (NFR2)
			} else {
				log.Println("[gateway] no host credential — channel routing only")
			}
			// The second line: the instance's peer key (nautilus Phase 4, 4.2). Only the id is logged;
			// it is public, the key is not.
			if peer := ReadPeerIdentity(rest); peer.Configured() {
				gw.SetPeerIdentity(peer)
				log.Printf("[gateway] peer id %s", peer.ID())
			}
			// The third line: the key that signs a remote caller's peer id (4.3). Never logged.
			if key := ReadAttestKey(rest); key != "" {
				gw.SetAttestKey(key)
			}
			// Remote callers arrive through relays (4.4), once this instance has a key to register.
			if list := splitRelays(*relays); len(list) > 0 && gw.peerKey() != nil {
				t := relay.NewTransport(gw.peerKey(), list)
				for _, r := range list {
					gw.SetRelayState(r, false)
				}
				t.OnState = gw.SetRelayState
				t.Run(context.Background())
				go gw.ServeRemote(context.Background(), t)
			}
			io.Copy(io.Discard, rest)
			log.Println("[gateway] parent pipe closed (EOF) — shutting down")
			done <- syscall.SIGTERM
		}()
	}

	go func() {
		log.Printf("[gateway] listening on %s", *addr)
		if err := srv.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatalf("[gateway] server error: %v", err)
		}
	}()

	<-done
	log.Println("[gateway] shutting down...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}

func splitRelays(s string) []string {
	var out []string
	for _, r := range strings.Split(s, ",") {
		if r = strings.TrimSpace(r); r != "" {
			out = append(out, r)
		}
	}
	return out
}

const rootPage = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Port42 — Companion Computing</title>
<meta name="title" content="Port42 — Companion Computing">
<meta name="description" content="A native macOS app where humans and AI companions coexist. No walls. No lock-in. Your companions, your rules.">
<meta name="author" content="Port42">
<meta name="theme-color" content="#00d4aa">
<meta property="og:type" content="website">
<meta property="og:title" content="Port42 — Companion Computing">
<meta property="og:description" content="A native macOS app where humans and AI companions coexist. No walls. No lock-in. Your companions, your rules.">
<meta property="og:image" content="https://port42.ai/cover.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:site_name" content="Port42">
<meta property="og:locale" content="en_US">
<meta property="og:video" content="https://port42.ai/dreamscape.mp4">
<meta property="og:video:type" content="video/mp4">
<meta property="twitter:card" content="summary_large_image">
<meta property="twitter:title" content="Port42 — Companion Computing">
<meta property="twitter:description" content="A native macOS app where humans and AI companions coexist. No walls. No lock-in. Your companions, your rules.">
<meta property="twitter:image" content="https://port42.ai/cover.png">
<meta property="twitter:player" content="https://port42.ai/dreamscape.mp4">
<meta property="twitter:player:width" content="1920">
<meta property="twitter:player:height" content="1080">
<link rel="icon" type="image/png" href="https://port42.ai/favicon.png">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
    background: #0a0a0a; color: #e0e0e0;
    display: flex; justify-content: center; align-items: center;
    min-height: 100vh; padding: 20px;
  }
  .card {
    max-width: 420px; width: 100%;
    border: 1px solid #222; border-radius: 12px;
    padding: 40px 32px; text-align: center;
    background: #111;
  }
  .logo { font-size: 32px; color: #00ff41; margin-bottom: 16px; }
  .brand { font-size: 14px; font-weight: 700; color: #00ff41; letter-spacing: 2px; margin-bottom: 24px; }
  p { font-size: 14px; color: #999; line-height: 1.6; margin-bottom: 20px; }
  .btn {
    display: inline-block; padding: 12px 24px;
    border: none; border-radius: 8px; cursor: pointer;
    font-family: inherit; font-size: 13px; font-weight: 600;
    text-decoration: none; background: #00ff41; color: #0a0a0a;
    transition: opacity 0.2s;
  }
  .btn:hover { opacity: 0.85; }
</style>
</head>
<body>
<div class="card">
  <div class="logo">&#x25CB;</div>
  <div class="brand">PORT42</div>
  <p>a companion gateway is running here</p>
  <a href="https://github.com/gordonmattey/port42-native/releases/latest/download/Port42.dmg" class="btn" download="Port42 Companion Computing.dmg">download Port42</a>
</div>
</body>
</html>
`

// newMux is the gateway's routes: the WebSocket door, `/call`, `/health` and the root page. The old
// `/port` browser-guest spike and its query-string token are gone (nautilus Phase 4, 4.7): a browser
// guest now comes through a relay, from the invite page (guest/, tele.port42.ai).
func newMux(gw *Gateway) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", gw.HandleWebSocket)
	mux.HandleFunc("/call", gw.HandleHTTPCall)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ngrok-skip-browser-warning", "true")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("ngrok-skip-browser-warning", "true")
		fmt.Fprint(w, rootPage)
	})

	return mux
}
