package main

import (
	"context"
	"flag"
	"fmt"
	"html"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	addr := flag.String("addr", ":4242", "listen address")
	flag.Parse()

	gw := NewGateway()

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", gw.HandleWebSocket)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ngrok-skip-browser-warning", "true")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("/invite", handleInvite)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("ngrok-skip-browser-warning", "true")
		fmt.Fprint(w, rootPage)
	})

	srv := &http.Server{
		Addr:    *addr,
		Handler: mux,
		// No read/write timeouts: WebSocket connections are long-lived
		// and timeouts would kill them (especially through reverse proxies/ngrok)
	}

	done := make(chan os.Signal, 1)
	signal.Notify(done, os.Interrupt, syscall.SIGTERM)

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

func handleInvite(w http.ResponseWriter, r *http.Request) {
	channelID := r.URL.Query().Get("id")
	channelName := r.URL.Query().Get("name")
	encKey := r.URL.Query().Get("key")
	if channelID == "" || channelName == "" {
		http.Error(w, "missing id or name", http.StatusBadRequest)
		return
	}

	// Build the gateway WS URL from the request host (no /ws suffix;
	// the client appends /ws when connecting)
	scheme := "wss"
	gateway := scheme + "://" + r.Host

	// Build port42:// deep link
	deepLink := fmt.Sprintf("port42://channel?gateway=%s&id=%s&name=%s",
		url.QueryEscape(gateway),
		url.QueryEscape(channelID),
		url.QueryEscape(channelName))
	if encKey != "" {
		deepLink += "&key=" + url.QueryEscape(encKey)
	}

	safeName := html.EscapeString(channelName)

	// Build the HTTPS invite page URL for sharing
	pageURL := fmt.Sprintf("https://%s/invite?id=%s&name=%s",
		r.Host,
		url.QueryEscape(channelID),
		url.QueryEscape(channelName))
	if encKey != "" {
		pageURL += "&key=" + url.QueryEscape(encKey)
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("ngrok-skip-browser-warning", "true")
	fmt.Fprintf(w, invitePage, safeName, safeName, safeName, safeName, deepLink, pageURL)
}

const invitePage = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Join #%s on Port42</title>
<meta property="og:type" content="website">
<meta property="og:title" content="Join #%s on Port42">
<meta property="og:description" content="You've been invited to swim in Port42, the aquarium for AI companions. Download the app, dive in, and start swimming together.">
<meta property="og:image" content="https://port42.ai/cover.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:site_name" content="Port42">
<meta property="twitter:card" content="summary_large_image">
<meta property="twitter:title" content="Join #%s on Port42">
<meta property="twitter:description" content="You've been invited to swim in Port42, the aquarium for AI companions. Download the app, dive in, and start swimming together.">
<meta property="twitter:image" content="https://port42.ai/cover.png">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
    background: #0a0a0a; color: #e0e0e0;
    display: flex; justify-content: center; align-items: center;
    min-height: 100vh; padding: 20px;
  }
  .card {
    max-width: 420px; width: 100%%;
    border: 1px solid #222; border-radius: 12px;
    padding: 40px 32px; text-align: center;
    background: #111;
  }
  .diamond { font-size: 32px; color: #00d4aa; margin-bottom: 16px; }
  .brand { font-size: 14px; font-weight: 700; color: #00d4aa; letter-spacing: 2px; margin-bottom: 24px; }
  h1 { font-size: 18px; font-weight: 400; margin-bottom: 8px; }
  h1 span { color: #00d4aa; }
  .steps { text-align: left; margin: 24px 0; font-size: 13px; color: #999; line-height: 2; }
  .steps strong { color: #e0e0e0; }
  .btn {
    display: block; width: 100%%; padding: 12px;
    border: none; border-radius: 8px; cursor: pointer;
    font-family: inherit; font-size: 13px; font-weight: 600;
    text-decoration: none; text-align: center;
    margin-bottom: 10px; transition: opacity 0.2s;
  }
  .btn:hover { opacity: 0.85; }
  .btn-primary { background: #00d4aa; color: #0a0a0a; }
  .btn-secondary { background: #222; color: #e0e0e0; }
  .note { font-size: 11px; color: #555; margin-top: 16px; }
</style>
</head>
<body>
<div class="card">
  <div class="diamond">&#x25C7;</div>
  <div class="brand">PORT42</div>
  <h1>join <span>#%s</span></h1>
  <div class="steps">
    <strong>1.</strong> download Port42 for macOS (Apple Silicon)<br>
    <strong>2.</strong> install the app and open it<br>
    <strong>3.</strong> once you're in the aquarium, come back and accept the invitation
  </div>
  <a href="https://github.com/gordonmattey/port42-native/raw/refs/heads/main/dist/Port42.dmg" class="btn btn-secondary">download Port42.dmg</a>
  <a href="%s" class="btn btn-primary" style="margin-top:10px;">accept invitation</a>
  <button class="btn btn-secondary" onclick="copyInvite()" style="border:none;cursor:pointer;margin-top:10px;">copy invite link</button>
  <p class="note" id="copy-msg" style="min-height:1.4em;"></p>
<script>
function copyInvite(){navigator.clipboard.writeText('%s').then(function(){document.getElementById('copy-msg').textContent='copied!';});}
</script>
</div>
</body>
</html>
`

const rootPage = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Port42</title>
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
  .diamond { font-size: 32px; color: #00d4aa; margin-bottom: 16px; }
  .brand { font-size: 14px; font-weight: 700; color: #00d4aa; letter-spacing: 2px; margin-bottom: 24px; }
  p { font-size: 14px; color: #999; line-height: 1.6; margin-bottom: 20px; }
  .btn {
    display: inline-block; padding: 12px 24px;
    border: none; border-radius: 8px; cursor: pointer;
    font-family: inherit; font-size: 13px; font-weight: 600;
    text-decoration: none; background: #00d4aa; color: #0a0a0a;
    transition: opacity 0.2s;
  }
  .btn:hover { opacity: 0.85; }
</style>
</head>
<body>
<div class="card">
  <div class="diamond">&#x25C7;</div>
  <div class="brand">PORT42</div>
  <p>a gateway is running here</p>
  <a href="https://github.com/gordonmattey/port42-native/raw/refs/heads/main/dist/Port42.dmg" class="btn">download Port42</a>
</div>
</body>
</html>
`
