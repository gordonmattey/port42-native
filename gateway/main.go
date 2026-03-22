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

// Injected at build time via -ldflags
var posthogAPIKey string

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

	// Initialize message store for history replay (survives restarts)
	dataDir := home + "/Library/Application Support/Port42"
	if msgStore, err := NewMessageStore(dataDir); err != nil {
		log.Printf("[gateway] message store disabled: %v", err)
	} else {
		gw.messageStore = msgStore
		defer msgStore.Close()
		log.Printf("[gateway] message store ready")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", gw.HandleWebSocket)
	mux.HandleFunc("/call", gw.HandleHTTPCall)
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
	// Build port42://openclaw deep link for one-click OpenClaw connection
	openclawDeepLink := fmt.Sprintf("port42://openclaw?invite=%s", url.QueryEscape(pageURL))

	// Fallback label for accept button when no host name
	acceptLabel := "first swim"
	if safeHost != "" {
		acceptLabel = safeHost
	}
	fmt.Fprintf(w, invitePage, safeName, safeName, ogDesc, pageURL, safeName, ogDesc, pageURL, safeName, ogDesc, safeName, hostLine, deepLink, acceptLabel, openclawDeepLink, posthogAPIKey)
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
    max-width: 760px; width: 100%%;
    text-align: center;
  }
  .logo { font-size: 32px; color: #00ff41; margin-bottom: 16px; }
  .brand { font-size: 14px; font-weight: 700; color: #00ff41; letter-spacing: 2px; margin-bottom: 24px; }
  h1 { font-size: 24px; font-weight: 400; margin-bottom: 24px; }
  h1 span { color: #00ff41; }
  .panels { display: flex; gap: 12px; }
  .panel {
    flex: 1; border: 1px solid #222; border-radius: 12px;
    padding: 28px 20px; background: #111;
    display: flex; flex-direction: column; align-items: center;
    text-align: center; transition: border-color 0.2s;
  }
  .panel:hover { border-color: #333; }
  .panel-icon { font-size: 24px; margin-bottom: 14px; }
  .panel-title { font-size: 13px; font-weight: 700; color: #e0e0e0; margin-bottom: 6px; }
  .panel-desc { font-size: 10px; color: #666; line-height: 1.5; margin-bottom: 18px; flex: 1; }
  .panel-btn {
    display: block; width: 100%%; padding: 10px 16px;
    border: none; border-radius: 8px; cursor: pointer;
    font-family: inherit; font-size: 12px; font-weight: 600;
    text-decoration: none; text-align: center;
    transition: opacity 0.2s;
  }
  .panel-btn:hover { opacity: 0.85; }
  .panel-btn-primary { background: #00ff41; color: #0a0a0a; }
  .panel-btn-secondary { background: #222; color: #e0e0e0; }
  .panel-btn-outline { background: transparent; color: #e0e0e0; border: 1px solid #333; }
  .panel-sub { font-size: 9px; font-weight: 400; color: #555; margin-top: 6px; }
  @media (max-width: 600px) {
    .panels { flex-direction: column; }
  }
</style>
</head>
<body>
<div class="card">
  <div class="logo">&#x25CB;</div>
  <div class="brand">PORT42</div>
  <h1>join <span>#%s</span></h1>
  %s
  <div class="panels">
    <div class="panel">
      <div class="panel-icon">&#x2B07;</div>
      <div class="panel-title">download</div>
      <div class="panel-desc">get Port42 for macOS</div>
      <a href="https://github.com/gordonmattey/port42-native/releases/latest/download/Port42.dmg" class="panel-btn panel-btn-outline" download="Port42 Companion Computing.dmg">Port42.dmg</a>
      <div class="panel-sub">Apple Silicon</div>
    </div>
    <div class="panel">
      <div class="panel-icon">&#x25CB;</div>
      <div class="panel-title">accept invite</div>
      <div class="panel-desc">swim into the channel</div>
      <a href="%s" class="panel-btn panel-btn-primary">accept</a>
      <div class="panel-sub">%s</div>
    </div>
    <div class="panel">
      <div class="panel-icon">&#x2699;</div>
      <div class="panel-title">connect agent</div>
      <div class="panel-desc">bring your openclaw agent</div>
      <a href="%s" class="panel-btn panel-btn-secondary">accept + connect</a>
      <div class="panel-sub">openclaw</div>
    </div>
  </div>
</div>
<script>
!function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.async=!0,p.src=s.api_host+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="capture identify alias people.set people.set_once set_config register register_once unregister opt_out_capturing has_opted_out_capturing opt_in_capturing reset isFeatureEnabled onFeatureFlags getFeatureFlag getFeatureFlagPayload reloadFeatureFlags group updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures getActiveMatchingSurveys getSurveys onSessionId".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);
var phKey="%s";
if(phKey){posthog.init(phKey,{api_host:"https://ph.port42.ai",autocapture:false,sanitize_properties:function(p,e){["$current_url","$pathname","$referrer","$initial_current_url","$initial_pathname","$initial_referrer","$pageview_url"].forEach(function(k){if(typeof p[k]==="string"){try{var u=new URL(p[k],location.origin);u.search="";p[k]=u.toString()}catch(x){p[k]=""}}});return p}});posthog.capture("invite_page_viewed");document.querySelectorAll(".panel-btn").forEach(function(b){b.addEventListener("click",function(ev){ev.preventDefault();var href=b.getAttribute("href");posthog.capture("invite_clicked",{action:b.textContent.trim().toLowerCase()},function(){if(href)window.location=href})})})}
</script>
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
  <a href="https://github.com/gordonmattey/port42-native/releases/latest/download/Port42.dmg" class="btn" download="Port42 Companion Computing.dmg">download Port42</a>
</div>
</body>
</html>
`
