package main

import (
	"strings"
	"testing"
)

// Slice-02 half two, 5a — the gateway's verifier.
//
// **The single real hazard in this file is format drift**: `p42_<id>_<mac>` has two implementations,
// `ClientRegistry.token` in Swift and `tokenMAC` here, and a mismatch means every token is silently
// rejected. `TestKnownVectorMatchesSwift` pins it against a value computed by the Swift side.

const testSecret = "dGVzdC1zZWNyZXQtbm90LWEtcmVhbC1vbmU="

func TestVerifyRoundTrip(t *testing.T) {
	tok := "p42_claude-code_" + tokenMAC("claude-code", testSecret)
	if got := VerifyToken(tok, testSecret); got != "claude-code" {
		t.Fatalf("want claude-code, got %q", got)
	}
}

// NFR4: instances are separated by their SECRETS, not by a path check.
func TestAnotherInstancesSecretDoesNotVerify(t *testing.T) {
	tok := "p42_claude-code_" + tokenMAC("claude-code", testSecret)
	if got := VerifyToken(tok, "a-different-instances-secret"); got != "" {
		t.Fatalf("a foreign token verified as %q", got)
	}
}

// The MAC is over the ID, so a token cannot be presented as a different client.
func TestTokenCannotBeReplayedAsAnotherClient(t *testing.T) {
	mac := tokenMAC("claude-code", testSecret)
	if got := VerifyToken("p42_gemini-cli_"+mac, testSecret); got != "" {
		t.Fatalf("a token was replayed as %q", got)
	}
}

func TestForgeriesAndJunkAreRefused(t *testing.T) {
	for _, tok := range []string{
		"", "claude-code", "p42_claude-code", "p42_claude-code_deadbeef",
		"xxx_claude-code_" + tokenMAC("claude-code", testSecret),
		// Not a valid slug: this is what stops a crafted id reaching a token file's name.
		"p42_../../etc/passwd_" + tokenMAC("../../etc/passwd", testSecret),
		"p42_UPPER_" + tokenMAC("UPPER", testSecret),
	} {
		if got := VerifyToken(tok, testSecret); got != "" {
			t.Errorf("token %q verified as %q", tok, got)
		}
	}
}

// With no secret the gateway can name nobody, and must not accidentally accept everybody.
func TestNoSecretVerifiesNothing(t *testing.T) {
	tok := "p42_claude-code_" + tokenMAC("claude-code", testSecret)
	if got := VerifyToken(tok, ""); got != "" {
		t.Fatalf("verified %q with no secret", got)
	}
	if (Credentials{}).HasRoot() {
		t.Fatal("empty credentials claimed to have a root secret")
	}
}

// `is_host` is unforgeable by anything on disk: the host secret is regenerated per spawn, so only a
// token minted with THIS spawn's secret is the host. Today any peer claiming is_host becomes it.
func TestHostCredentialIsDistinctFromAClientToken(t *testing.T) {
	c := Credentials{Root: testSecret, Host: "host-secret-for-this-spawn"}

	hostTok := "p42_host_" + tokenMAC("host", c.Host)
	if id, isHost := c.PrincipalFor(hostTok); !isHost || id != "host" {
		t.Fatalf("host credential not recognised: id=%q isHost=%v", id, isHost)
	}

	// A CLIENT token, even one naming itself "host", is not the host — it is signed with the wrong key.
	clientClaimingHost := "p42_host_" + tokenMAC("host", c.Root)
	if _, isHost := c.PrincipalFor(clientClaimingHost); isHost {
		t.Fatal("a client-signed token claiming to be host was accepted as host")
	}

	// And an ordinary client still resolves, as itself, not as host.
	clientTok := "p42_claude-code_" + tokenMAC("claude-code", c.Root)
	id, isHost := c.PrincipalFor(clientTok)
	if id != "claude-code" || isHost {
		t.Fatalf("client resolved wrong: id=%q isHost=%v", id, isHost)
	}
}

// Spike C's carried detail: the death-watch must resume from the SAME buffered reader, or whatever the
// buffer already pulled in is lost. A test rather than a comment, because the loss is invisible.
func TestReadCredentialsReturnsAReaderThatKeepsTheRest(t *testing.T) {
	stdin := strings.NewReader("root-secret\nhost-secret\nleftover-payload\n")
	creds, r := ReadCredentials(stdin)

	if creds.Root != "root-secret" || creds.Host != "host-secret" {
		t.Fatalf("secrets wrong: %+v", creds)
	}
	rest, _ := r.ReadString('\n')
	if strings.TrimRight(rest, "\n") != "leftover-payload" {
		t.Fatalf("the buffered reader lost data after the secrets: %q", rest)
	}
}

func TestReadCredentialsToleratesAnEmptyPipe(t *testing.T) {
	// A hand-launched relay has no pipe. It must not block or panic, and must report no root secret
	// so it serves routing only rather than pretending it can name callers.
	creds, _ := ReadCredentials(strings.NewReader(""))
	if creds.HasRoot() {
		t.Fatal("an empty pipe produced a root secret")
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

// THE DRIFT GATE, and the only real hazard in this file.
//
// `p42_<id>_<mac>` has TWO implementations — `ClientRegistry.mac` in Swift and `tokenMAC` here. If
// they diverge, every token the app mints is silently rejected by the gateway, and nothing anywhere
// says so: the symptom is "authentication just doesn't work", with both sides individually correct.
//
// This vector was computed independently of both (HMAC-SHA256, base64url, unpadded), so it pins the
// FORMAT rather than one implementation's opinion of it. The matching assertion on the Swift side is
// `ClientRegistryTests.tokenFormatMatchesTheGateway`.
func TestKnownVectorMatchesSwift(t *testing.T) {
	const wantMAC = "5U2Q9QduHVJNxsiJy6go6uItuDpLFuVdtf8pD4zRFHA"
	if got := tokenMAC("claude-code", testSecret); got != wantMAC {
		t.Fatalf("MAC format drifted:\n got:  %s\n want: %s", got, wantMAC)
	}
}
