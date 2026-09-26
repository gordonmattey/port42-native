package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"io"
	"strings"
	"testing"
	"time"
)

// RFC 8032 section 7.1, test 1. The expected id was computed outside Go (Python's base64.b32encode,
// lowercased, padding stripped), so this pins the encoding against a second implementation.
const (
	rfc8032Seed64 = "nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
	rfc8032Pub    = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
	rfc8032PeerID = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
)

func TestPeerIDIsLowercaseBase32OfThePublicKey(t *testing.T) {
	pub, _ := hex.DecodeString(rfc8032Pub)
	if got := PeerIDFromPublicKey(ed25519.PublicKey(pub)); got != rfc8032PeerID {
		t.Fatalf("peer id %q, want %q", got, rfc8032PeerID)
	}
	if len(rfc8032PeerID) != 52 || strings.ToLower(rfc8032PeerID) != rfc8032PeerID {
		t.Fatalf("a peer id is 52 lowercase characters")
	}
}

func TestTheSecondHandoverLineIsThePeerKey(t *testing.T) {
	stdin := strings.NewReader("host-credential\n" + rfc8032Seed64 + "\nleft for the death-watch")
	cred, rest := ReadHostCredential(stdin)
	peer := ReadPeerIdentity(rest)
	if !cred.Matches("host-credential") {
		t.Fatalf("the host credential is still the first line")
	}
	if peer.ID() != rfc8032PeerID {
		t.Fatalf("peer id %q from the handed-over seed, want %q", peer.ID(), rfc8032PeerID)
	}
	left, _ := io.ReadAll(rest)
	if string(left) != "left for the death-watch" {
		t.Fatalf("reading the peer key consumed what follows it: %q", left)
	}
}

func TestNoOrBadPeerKeyMeansNoPeerID(t *testing.T) {
	for _, line := range []string{"", "not base64!\n", "c2hvcnQ=\n"} {
		_, rest := ReadHostCredential(strings.NewReader("host\n" + line))
		if p := ReadPeerIdentity(rest); p.Configured() || p.ID() != "" {
			t.Fatalf("line %q gave a peer id %q", line, p.ID())
		}
	}
}

func TestOnlyTheProvenHostIsToldThePeerID(t *testing.T) {
	gw := NewGateway()
	cred, rest := ReadHostCredential(strings.NewReader("the-host\n" + rfc8032Seed64 + "\n"))
	gw.SetHostCredential(cred)
	gw.SetPeerIdentity(ReadPeerIdentity(bufio.NewReader(rest)))
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	welcomeFor := func(id string, host bool, credential string) Envelope {
		conn, _ := dialAndRead(t, ctx, wsURL) // no_auth
		t.Cleanup(func() { conn.CloseNow() })
		sendEnvelope(t, ctx, conn, Envelope{Type: "identify", SenderID: id, IsHost: host,
			HostCredential: credential})
		return readEnvelope(t, ctx, conn)
	}

	if w := welcomeFor("the-app", true, "the-host"); w.SelfPeer != rfc8032PeerID {
		t.Fatalf("the proven host's welcome carries %q, want the peer id", w.SelfPeer)
	}
	if w := welcomeFor("a-caller", false, ""); w.SelfPeer != "" {
		t.Fatalf("a caller was told the peer id: %q", w.SelfPeer)
	}
	if w := welcomeFor("an-impostor", true, "wrong"); w.SelfPeer != "" {
		t.Fatalf("a host claim with the wrong credential was told the peer id: %q", w.SelfPeer)
	}
}
