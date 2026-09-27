package open

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Every file goes out with the headers that keep a guest's key its own, the frame with a port's
// policy and the page with the strict one; nothing else is served.
func TestTheInvitePageIsServedWithItsHeaders(t *testing.T) {
	srv := httptest.NewServer(Handler("../../guest"))
	defer srv.Close()
	get := func(path string) *http.Response {
		r, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		return r
	}
	for _, path := range []string{"/", "/invite.html"} {
		r := get(path)
		if r.StatusCode != 200 || r.Header.Get("Content-Security-Policy") != PageCSP {
			t.Errorf("%s: %d, policy %q", path, r.StatusCode, r.Header.Get("Content-Security-Policy"))
		}
		if r.Header.Get("Referrer-Policy") != "no-referrer" || r.Header.Get("X-Frame-Options") != "DENY" {
			t.Errorf("%s: missing referrer or framing headers: %v", path, r.Header)
		}
	}
	if directive(PageCSP, "script-src") != "script-src 'self'" {
		t.Errorf("the page's policy lets inline or foreign script run: %s", PageCSP)
	}
	if r := get("/frame.html"); r.Header.Get("Content-Security-Policy") != FrameCSP || r.Header.Get("X-Frame-Options") != "" {
		t.Errorf("frame.html: policy %q, framing %q", r.Header.Get("Content-Security-Policy"), r.Header.Get("X-Frame-Options"))
	}
	if !strings.Contains(FrameCSP, "default-src 'none'") || strings.Contains(FrameCSP, "connect-src") {
		t.Errorf("a shared port's frame can reach the network: %s", FrameCSP)
	}
	if r := get("/dist/port42-guest.js"); r.StatusCode != 200 || !strings.HasPrefix(r.Header.Get("Content-Type"), "text/javascript") {
		t.Errorf("the script: %d %s", r.StatusCode, r.Header.Get("Content-Type"))
	}
	for _, path := range []string{"/package.json", "/src/guest.js", "/../gateway/main.go", "/node_modules/"} {
		if r := get(path); r.StatusCode != 404 {
			t.Errorf("%s was served (%d)", path, r.StatusCode)
		}
	}
}

func directive(csp, name string) string {
	for _, d := range strings.Split(csp, ";") {
		if d = strings.TrimSpace(d); strings.HasPrefix(d, name+" ") {
			return d
		}
	}
	return ""
}
