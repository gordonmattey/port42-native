package tele

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/port42/gateway/relay"
)

// tele serves the commit it was built from too, so a deploy can tell the new page from the old.
func TestTeleServesTheCommitItWasBuiltFrom(t *testing.T) {
	was := relay.Commit
	relay.Commit = "abc1234"
	defer func() { relay.Commit = was }()
	srv := httptest.NewServer(Handler("../../guest"))
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
