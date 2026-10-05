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

// #273: an @mention is text, not a file; a file is still read; a missing path is still an error.
func TestAnAtMentionIsTextNotAFile(t *testing.T) {
	dir := t.TempDir()
	page := dir + "/port.html"
	os.WriteFile(page, []byte("<p>hi</p>"), 0o600)
	for _, c := range []struct{ word, want string }{
		{"text=@wren hello", "@wren hello"},
		{"text=@wren", "@wren"},
		{"html=@" + page, "<p>hi</p>"},
	} {
		got, err := parseMethodArgs([]string{c.word}, strings.NewReader(""))
		if err != nil {
			t.Fatalf("%q: %v", c.word, err)
		}
		for _, v := range got {
			if v != c.want {
				t.Fatalf("%q gave %q, want %q", c.word, v, c.want)
			}
		}
	}
	if _, err := parseMethodArgs([]string{"html=@" + dir + "/prot.htm"}, strings.NewReader("")); err == nil {
		t.Fatal("a mistyped file path was sent as text instead of failing")
	}
}
