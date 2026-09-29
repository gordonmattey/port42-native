package relay

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// A deploy checks /version against the commit it built, so the relay must serve the one it was built
// with, not a constant.
func TestTheRelayServesTheCommitItWasBuiltFrom(t *testing.T) {
	was := Commit
	Commit = "abc1234"
	defer func() { Commit = was }()
	srv := httptest.NewServer(NewServer(DefaultLimits).Handler())
	defer srv.Close()
	r, err := http.Get(srv.URL + "/version")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r.Body)
	r.Body.Close()
	if r.StatusCode != 200 || string(b) != "abc1234" {
		t.Errorf("/version: %d %q, want the build's commit", r.StatusCode, b)
	}
}
