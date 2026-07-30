package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"io"
	"strings"
)

// Credential verification for the gateway (slice-02 half two, D2/D3).
//
// The gateway's job here is deliberately tiny: turn a credential into a principal id, or into
// nothing. It holds ONE secret and NO client table, consults no filesystem, and stores nothing — which
// is what lets it survive its own restart with no state to rebuild (NFR5), and what keeps revocation
// instant without restarting it (the APP decides whether a verified client still exists; D6 splits
// steps 2 and 5 across the two components for exactly that reason).
//
// **This file cannot refuse anything.** It answers "who is this", and the caller decides what to do
// with silence. Enforcement is a separate change (5b), landing once every first-party caller
// demonstrably carries a token.

// Credentials the parent app hands the gateway at spawn.
type Credentials struct {
	// Mints and verifies client tokens. Instance-qualified in the app's Keychain, so a token minted
	// by Dev3 fails production's verification and instance separation falls out of the secret rather
	// than out of a path check (NFR4).
	Root string
	// Regenerated on EVERY gateway spawn and never written anywhere, which is what makes `is_host`
	// unforgeable by anything on disk: a stale host credential cannot outlive the app that minted it.
	Host string
}

// HasRoot reports whether client tokens can be verified at all. A gateway launched by hand (no
// `-watch-parent`, so no secrets) serves channel routing only — it can route messages but cannot
// name a caller, and must therefore not pretend to.
func (c Credentials) HasRoot() bool { return c.Root != "" }

// ReadCredentials takes two lines — root, then host — from the pipe the parent app already holds.
//
// **Over stdin, NOT the environment**, and that is measured rather than stylistic: `ps -E` returns a
// same-user process's full environment, so handing the gateway a secret at spawn via the environment
// would publish it to every process running as the user, which is the exact escalation this whole
// slice exists to close.
//
// Returns the SAME reader for the caller to continue with. This matters: the EOF-death-watch reads
// stdin after this, and resuming from `os.Stdin` instead of this buffered reader would discard
// whatever the buffer had already pulled in (spike C's one carried detail).
func ReadCredentials(stdin io.Reader) (Credentials, *bufio.Reader) {
	r := bufio.NewReader(stdin)
	root, err := r.ReadString('\n')
	if err != nil && root == "" {
		return Credentials{}, r
	}
	host, _ := r.ReadString('\n')
	return Credentials{
		Root: strings.TrimRight(root, "\r\n"),
		Host: strings.TrimRight(host, "\r\n"),
	}, r
}

// tokenMAC is base64url-unpadded HMAC-SHA256 over the ID, under the given secret.
//
// Over the ID, so a token cannot be replayed as a different client: the MAC binds the name it
// carries. Must stay byte-identical to `ClientRegistry.mac` on the Swift side — the two are one
// format with two implementations, which is the only real hazard in this file.
func tokenMAC(id, secret string) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(id))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// validSlug mirrors the Swift side: [a-z0-9-]. It is what guarantees `p42_<id>_<mac>` splits into
// exactly three parts, and it stops a crafted id smuggling a path separator into a token file name.
func validSlug(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
			continue
		}
		return false
	}
	return true
}

// VerifyToken returns the client id a token names, or "" if it does not verify.
//
// `hmac.Equal` is constant-time (NFR1): comparing MACs with `==` leaks how much of a forgery was
// correct through timing, which is enough to build one a byte at a time.
func VerifyToken(token, secret string) string {
	if secret == "" || token == "" {
		return ""
	}
	parts := strings.SplitN(token, "_", 3)
	if len(parts) != 3 || parts[0] != "p42" {
		return ""
	}
	id, presented := parts[1], parts[2]
	if !validSlug(id) {
		return ""
	}
	if !hmac.Equal([]byte(tokenMAC(id, secret)), []byte(presented)) {
		return ""
	}
	return id
}

// PrincipalFor resolves a presented credential to a principal id.
//
// The host credential is the same construction over the host secret with `id = host`, so one routine
// covers both and they differ only in WHICH SECRET is used. That is what makes `is_host` checkable at
// all: today any peer claiming `is_host: true` becomes the host every `/call` is routed to.
func (c Credentials) PrincipalFor(token string) (id string, isHost bool) {
	if id := VerifyToken(token, c.Host); id == "host" {
		return "host", true
	}
	return VerifyToken(token, c.Root), false
}

// BearerToken pulls a token out of an Authorization header value. Empty when absent or malformed —
// never an error, because "no credential" is an ordinary state on this door until 5b.
func BearerToken(header string) string {
	const prefix = "Bearer "
	if len(header) <= len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(header[len(prefix):])
}
