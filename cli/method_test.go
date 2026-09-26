package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMethodArgsForms(t *testing.T) {
	dir := t.TempDir()
	html := `<div class="a">it's "quoted" $HOME</div>`
	f := filepath.Join(dir, "port.html")
	if err := os.WriteFile(f, []byte(html), 0o600); err != nil {
		t.Fatal(err)
	}
	args, err := parseMethodArgs([]string{"id=P1", "limit:=20", "html=@" + f, "text=a=b", `{"extra":true}`},
		strings.NewReader(""))
	if err != nil {
		t.Fatal(err)
	}
	if args["id"] != "P1" || args["limit"] != float64(20) || args["extra"] != true {
		t.Fatalf("got %v", args)
	}
	if args["html"] != html {
		t.Fatalf("a file must arrive byte for byte, got %q", args["html"])
	}
	if args["text"] != "a=b" {
		t.Fatalf("only the first = splits: got %q", args["text"])
	}
	in, _ := parseMethodArgs([]string{"html=@-"}, strings.NewReader("from stdin"))
	if in["html"] != "from stdin" {
		t.Fatalf("stdin: got %q", in["html"])
	}
	if _, err := parseMethodArgs([]string{"loose"}, strings.NewReader("")); err == nil {
		t.Fatal("a word that is no argument form must be refused, not dropped")
	}
}

// A session Port42 started calls as itself, on its own instance: presenting the CLI's install
// credential there would be borrowing another client's identity.
func TestASessionCallsAsItself(t *testing.T) {
	dir := t.TempDir()
	tok := filepath.Join(dir, "tok")
	os.WriteFile(tok, []byte("session-token\n"), 0o600)
	env := map[string]string{"PORT42_TOKEN_FILE": tok, "PORT42_GATEWAY_PORT": "4246"}
	port, token, err := callerCredential(0, func(k string) string { return env[k] })
	if err != nil || port != 4246 || token != "session-token" {
		t.Fatalf("got %d %q %v", port, token, err)
	}
	if p, _, _ := callerCredential(4245, func(k string) string { return env[k] }); p != 4245 {
		t.Fatalf("--port must win, got %d", p)
	}
}

func TestRefusalIsRecognisedAndUnwrapped(t *testing.T) {
	c := unwrap([]byte(`"{\"error\":\"stale\",\"code\":\"stale_write\",\"current\":\"t:4\"}"`))
	obj, ok := bridgeError(c)
	if !ok || obj["current"] != "t:4" {
		t.Fatalf("a refusal must be seen, with current: %s", c)
	}
	if _, ok := bridgeError([]byte(`{"error":"a field named error"}`)); ok {
		t.Fatal("a result with an error field but no code is a result")
	}
	if string(unwrap([]byte(`"plain text"`))) != `"plain text"` {
		t.Fatal("text stays text")
	}
}
