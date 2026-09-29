// Package tele serves the invite page (nautilus Phase 4, 4.7): one page for every Port42, a
// guest-only Port42 in the browser. It serves three files, each with the headers that keep the
// guest's key its own: the page, the frame a shared port runs in, and the page's script.
package tele

import (
	"net/http"
	"os"
	"path/filepath"

	"github.com/port42/gateway/relay"
)

// PageCSP is the page's policy: scripts only from this origin (so nothing injected can run and read
// the guest's key), connections only to secure WebSocket relays (any relay: an invite names its
// host's, and people may run their own), frames only from this origin, and nothing else.
const PageCSP = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src wss:; " +
	"frame-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

// FrameCSP is the frame's: what Port42 gives a port in the app (PortWindowManager), so a port runs the
// same in a browser as in a tile, plus no form submission and no <base> (GST-01). The port cannot
// fetch, connect or post a form anywhere.
//
// It is NOT sealed from the network: no CSP directive stops a page navigating its own frame, so a
// port can still carry data out in a URL it navigates to. Treat "can reach no network" as untrue
// until navigation is blocked too.
const FrameCSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; " +
	"form-action 'none'; base-uri 'none'; frame-ancestors 'self'"

// Handler serves the site in dir: invite.html at / and /invite.html, frame.html, dist/port42-guest.js.
func Handler(dir string) http.Handler {
	files := map[string]struct{ file, typ, csp string }{
		"/":                     {"invite.html", "text/html; charset=utf-8", PageCSP},
		"/invite.html":          {"invite.html", "text/html; charset=utf-8", PageCSP},
		"/frame.html":           {"frame.html", "text/html; charset=utf-8", FrameCSP},
		"/dist/port42-guest.js": {"dist/port42-guest.js", "text/javascript; charset=utf-8", ""},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(relay.Commit)) })
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		f, ok := files[r.URL.Path]
		if !ok || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
			http.NotFound(w, r)
			return
		}
		body, err := os.ReadFile(filepath.Join(dir, f.file))
		if err != nil {
			http.Error(w, "not built", http.StatusServiceUnavailable)
			return
		}
		h := w.Header()
		h.Set("Content-Type", f.typ)
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cache-Control", "no-cache")
		if f.csp != "" {
			h.Set("Content-Security-Policy", f.csp)
		}
		if r.URL.Path != "/frame.html" {
			h.Set("X-Frame-Options", "DENY")
		}
		w.Write(body)
	})
	return mux
}
