package main

import (
	"os"
	"strings"
	"testing"
)

// Slice-02 half two, 5a — the gateway's half of authentication.
//
// **The most useful test in this file is `TestNoTokenFormatLivesInTheGateway`**, which asserts an
// ABSENCE. The first version of this file reimplemented `p42_<id>_<mac>` alongside Swift and pinned the
// two with a shared vector; a gate is not a fix, because two implementations can still diverge and the
// symptom is every token silently rejected while both sides stay green. The duplicate is deleted, and
// that test is what stops it coming back.

func TestHostCredentialMatchesOnlyItself(t *testing.T) {
	h, _ := ReadHostCredential(strings.NewReader("the-host-credential-for-this-spawn\n"))
	if !h.Configured() {
		t.Fatal("credential not read")
	}
	if !h.Matches("the-host-credential-for-this-spawn") {
		t.Fatal("the real credential did not match")
	}
	for _, wrong := range []string{
		"", "the-host-credential-for-this-spaw", // truncated: length mismatch must fail
		"the-host-credential-for-this-spawnX",
		"THE-HOST-CREDENTIAL-FOR-THIS-SPAWN", // no case folding on a credential
	} {
		if h.Matches(wrong) {
			t.Errorf("%q was accepted as the host", wrong)
		}
	}
}

// A gateway launched by hand has no pipe. It must not block, and must not accept everybody by
// answering "no expectation, so anything matches".
func TestUnconfiguredCredentialAcceptsNothing(t *testing.T) {
	h, _ := ReadHostCredential(strings.NewReader(""))
	if h.Configured() {
		t.Fatal("an empty pipe produced a credential")
	}
	for _, claim := range []string{"", "anything", "p42_host_whatever"} {
		if h.Matches(claim) {
			t.Errorf("unconfigured credential accepted %q", claim)
		}
	}
}

// Spike C's carried detail: the death-watch must resume from the SAME buffered reader, or whatever the
// buffer already pulled in is lost. A test rather than a comment, because the loss is invisible.
func TestReadReturnsAReaderThatKeepsTheRest(t *testing.T) {
	stdin := strings.NewReader("host-credential\nleftover-payload\n")
	h, r := ReadHostCredential(stdin)

	if h.expected != "host-credential" {
		t.Fatalf("credential wrong: %q", h.expected)
	}
	rest, _ := r.ReadString('\n')
	if strings.TrimRight(rest, "\n") != "leftover-payload" {
		t.Fatalf("the buffered reader lost data after the credential: %q", rest)
	}
}

func TestBearerTokenParsing(t *testing.T) {
	cases := map[string]string{
		"Bearer p42_a_b":  "p42_a_b",
		"bearer p42_a_b":  "p42_a_b", // scheme is case-insensitive per RFC 7235
		"Bearer  p42_a_b": "p42_a_b",
		"":                "",
		"Bearer":          "",
		"Bearer ":         "",
		"Basic p42_a_b":   "",
		"p42_a_b":         "",
	}
	for header, want := range cases {
		if got := BearerToken(header); got != want {
			t.Errorf("BearerToken(%q) = %q, want %q", header, got, want)
		}
	}
}

// **THE GATE THAT MATTERS: no token format may exist in the gateway.**
//
// Client tokens are minted AND verified by the app, in `ClientRegistry`, so there is exactly one
// implementation of `p42_<id>_<mac>` and nothing to drift from. This gateway forwards a credential as an
// opaque string and never inspects it.
//
// Asserted structurally, because the failure it prevents is invisible: a well-meaning change that
// "helpfully" verifies here would recreate the duplicate, both suites would stay green, and the two
// implementations would drift apart later under a change to one of them.
func TestNoTokenFormatLivesInTheGateway(t *testing.T) {
	src := readSource(t, "credentials.go")
	for _, forbidden := range []string{
		"crypto/hmac",   // verifying a MAC means reimplementing the format
		"crypto/sha256", // …
		"p42_",          // parsing the token's shape
		"base64",        // decoding its MAC
	} {
		if strings.Contains(stripComments(src), forbidden) {
			t.Errorf("the token format is creeping back into the gateway (%q). "+
				"Client tokens are verified by the app — one implementation, nothing to drift.",
				forbidden)
		}
	}
}

// readSource reads a file in this package, for the structural gate above.
func readSource(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(name)
	if err != nil {
		t.Fatalf("cannot read %s: %v", name, err)
	}
	return string(b)
}

// stripComments removes // line comments so the gate does not fire on the prose EXPLAINING what must
// not be here — this file and credentials.go both name `p42_` and `crypto/hmac` while forbidding them.
func stripComments(src string) string {
	var out strings.Builder
	for _, line := range strings.Split(src, "\n") {
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		out.WriteString(line)
		out.WriteString("\n")
	}
	return out.String()
}
