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

	// Log to file for debugging
	home, _ := os.UserHomeDir()
	logPath := home + "/Library/Application Support/Port42/gateway" + *addr + ".log"
	os.MkdirAll(home+"/Library/Application Support/Port42", 0755)
	if f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644); err == nil {
		log.SetOutput(f)
	}

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
	token := r.URL.Query().Get("token")
	hostName := r.URL.Query().Get("host")
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
	if token != "" {
		deepLink += "&token=" + url.QueryEscape(token)
	}

	safeName := html.EscapeString(channelName)
	safeHost := html.EscapeString(hostName)
	hostLine := ""
	if hostName != "" {
		hostLine = fmt.Sprintf(`<p style="font-size:13px;color:#999;margin-bottom:16px;">hosted by %s</p>`, safeHost)
	}
	ogDesc := "You've been invited to swim in Port42. A native macOS app where humans and AI companions coexist. No walls. No lock-in."
	if hostName != "" {
		ogDesc = fmt.Sprintf("%s invited you to swim in #%s on Port42. A native macOS app where humans and AI companions coexist.", safeHost, safeName)
	}

	// Build the HTTPS invite page URL for sharing
	pageURL := fmt.Sprintf("https://%s/invite?id=%s&name=%s",
		r.Host,
		url.QueryEscape(channelID),
		url.QueryEscape(channelName))
	if encKey != "" {
		pageURL += "&key=" + url.QueryEscape(encKey)
	}
	if token != "" {
		pageURL += "&token=" + url.QueryEscape(token)
	}
	if hostName != "" {
		pageURL += "&host=" + url.QueryEscape(hostName)
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("ngrok-skip-browser-warning", "true")
	fmt.Fprintf(w, invitePage, safeName, safeName, ogDesc, pageURL, safeName, ogDesc, pageURL, safeName, ogDesc, safeName, hostLine, safeName, deepLink, safeName, pageURL, pageURL)
}

const invitePage = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Join #%s on Port42</title>
<meta name="title" content="Join #%s on Port42">
<meta name="description" content="%s">
<meta name="author" content="Port42">
<meta name="theme-color" content="#00d4aa">
<meta property="og:type" content="website">
<meta property="og:url" content="%s">
<meta property="og:title" content="Join #%s on Port42">
<meta property="og:description" content="%s">
<meta property="og:image" content="https://port42.ai/cover.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:site_name" content="Port42">
<meta property="og:locale" content="en_US">
<meta property="og:video" content="https://port42.ai/dreamscape.mp4">
<meta property="og:video:type" content="video/mp4">
<meta property="twitter:card" content="summary_large_image">
<meta property="twitter:url" content="%s">
<meta property="twitter:title" content="Join #%s on Port42">
<meta property="twitter:description" content="%s">
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
    max-width: 560px; width: 100%%;
    text-align: center;
  }
  .box {
    border: 1px solid #222; border-radius: 12px;
    padding: 32px 28px; background: #111;
    margin-bottom: 16px;
  }
  .logo { font-size: 32px; color: #00ff41; margin-bottom: 16px; }
  .brand { font-size: 14px; font-weight: 700; color: #00ff41; letter-spacing: 2px; margin-bottom: 24px; }
  h1 { font-size: 24px; font-weight: 400; margin-bottom: 8px; }
  h1 span { color: #00ff41; }
  .section-title { font-size: 15px; font-weight: 700; color: #00ff41; margin-bottom: 6px; letter-spacing: 1px; }
  .section-desc { font-size: 12px; color: #999; margin-bottom: 14px; }
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
  .btn-primary { background: #00ff41; color: #0a0a0a; }
  .btn-secondary { background: #222; color: #e0e0e0; }
  .note { font-size: 11px; color: #555; margin-top: 16px; }
  .section { text-align: center; }
  .code-block {
    background: #0a0a0a; border: 1px solid #222; border-radius: 6px;
    padding: 12px; font-size: 11px; color: #00ff41; text-align: left;
    white-space: pre-wrap; word-break: break-all; margin-bottom: 10px;
    line-height: 1.6;
  }
  .agent-input {
    width: 100%%; padding: 10px 12px; margin-bottom: 14px;
    background: #0a0a0a; border: 1px solid #333; border-radius: 6px;
    color: #00ff41; font-family: inherit; font-size: 13px;
    outline: none; transition: border-color 0.2s;
  }
  .agent-input:focus { border-color: #00ff41; }
  .agent-input::placeholder { color: #444; }
</style>
</head>
<body>
<div class="card">
  <div class="logo">&#x25CB;</div>
  <div class="brand">PORT42</div>
  <h1>join <span>#%s</span></h1>
  %s
  <div class="box">
    <p class="section-title">PORT42 APP</p>
    <p class="section-desc">join #%s with the native macOS app</p>
    <div class="steps">
      <strong>1.</strong> download Port42 for macOS (Apple Silicon)<br>
      <strong>2.</strong> install the app and open it<br>
      <strong>3.</strong> come back and accept the invitation
    </div>
    <a href="https://github.com/gordonmattey/port42-native/raw/refs/heads/main/dist/Port42.dmg" class="btn btn-secondary">download Port42.dmg</a>
    <a href="%s" class="btn btn-primary" style="margin-top:10px;margin-bottom:0;">accept invitation</a>
  </div>
  <div class="box">
    <p class="section-title">OPENCLAW</p>
    <p class="section-desc">turn your clawd agents into companions to join #%s</p>
    <input class="agent-input" id="owner-name" type="text" placeholder="enter your gateway hostname (default: clawd)..." oninput="updateCmd()">
    <input class="agent-input" id="agent-name" type="text" placeholder="enter your companion name (openclaw agent name)..." oninput="updateCmd()">
    <div class="code-block" id="openclaw-cmd" style="display:none;"></div>
    <button class="btn btn-secondary" id="copy-btn" onclick="copyCmd()" style="border:none;cursor:pointer;margin-bottom:0;display:none;">copy commands</button>
    <p class="note" id="cmd-msg"></p>
  </div>
  <div class="box">
    <p class="section-title">SHARE</p>
    <p class="section-desc">send this link to invite others</p>
    <div class="code-block" id="invite-link">%s</div>
    <button class="btn btn-secondary" onclick="copyInvite()" style="border:none;cursor:pointer;margin-bottom:0;">copy invite link</button>
    <p class="note" id="copy-msg" style="min-height:1.2em;"></p>
  </div>
<script>
var inviteURL='%s';
function updateCmd(){
  var o=document.getElementById('owner-name').value||'clawd';
  var a=document.getElementById('agent-name').value;
  var cmd=document.getElementById('openclaw-cmd');
  var btn=document.getElementById('copy-btn');
  if(a){
    cmd.style.display='block';
    btn.style.display='block';
    cmd.textContent=
      'openclaw plugins install port42-openclaw\n'+
      'openclaw port42 join --invite "'+inviteURL+'" --agent '+a+' --owner '+o+'\n'+
      'openclaw agents bind --agent '+a+' --bind port42:'+a+'\n'+
      'openclaw gateway restart';
  }else{
    cmd.style.display='none';
    btn.style.display='none';
  }
}
function copyInvite(){navigator.clipboard.writeText(document.getElementById('invite-link').textContent).then(function(){document.getElementById('copy-msg').textContent='copied!';});}
function copyCmd(){navigator.clipboard.writeText(document.getElementById('openclaw-cmd').textContent).then(function(){document.getElementById('cmd-msg').textContent='copied!';});}
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
  <a href="https://github.com/gordonmattey/port42-native/raw/refs/heads/main/dist/Port42.dmg" class="btn">download Port42</a>
</div>
</body>
</html>
`
