package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

const testAttestKey = "attest-key-for-this-spawn"

// remoteWorld: a gateway with a host credential and (optionally) an attestation key, the app's host
// connection, and a guest on another "machine" over the in-memory transport.
func remoteWorld(t *testing.T, attestKey string) (ctx context.Context, host func() Envelope,
	hostSend func(Envelope), guest Session, wsURL string) {
	t.Helper()
	gw := NewGateway()
	cred, _ := ReadHostCredential(strings.NewReader("the-host\n"))
	gw.SetHostCredential(cred)
	gw.SetAttestKey(attestKey)
	srv, url := setupTestServer(gw)
	t.Cleanup(srv.Close)
	c, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)

	hostConn, _ := dialAndRead(t, c, url)
	sendEnvelope(t, c, hostConn, Envelope{Type: "identify", SenderID: "the-app", IsHost: true, HostCredential: "the-host"})
	readEnvelope(t, c, hostConn) // welcome

	net := NewMemNetwork()
	here := net.Join("this-instance")
	go gw.ServeRemote(c, here)
	g, err := net.Join("guest-instance").Dial(c, "this-instance")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return c, func() Envelope { return readEnvelope(t, c, hostConn) },
		func(e Envelope) { sendEnvelope(t, c, hostConn, e) }, g, url
}

func guestSend(t *testing.T, ctx context.Context, s Session, env Envelope) {
	t.Helper()
	b, _ := json.Marshal(env)
	if err := s.Send(ctx, b); err != nil {
		t.Fatalf("guest send: %v", err)
	}
}

func guestRecv(t *testing.T, ctx context.Context, s Session) Envelope {
	t.Helper()
	b, err := s.Recv(ctx)
	if err != nil {
		t.Fatalf("guest recv: %v", err)
	}
	var env Envelope
	json.Unmarshal(b, &env)
	return env
}

func TestARemoteCallReachesTheHostStampedAndItsRepliesComeBack(t *testing.T) {
	ctx, host, hostSend, guest, _ := remoteWorld(t, testAttestKey)

	// The guest tries to bring a token and to name itself. Neither survives.
	guestSend(t, ctx, guest, Envelope{Type: "call", Method: "port.getHtml", CallID: "c1",
		Args: json.RawMessage(`{"id":"P"}`), Credential: "p42_stolen_token",
		RemotePeer: "someone-else", RemoteAttest: "forged"})

	call := host()
	if call.Type != "call" || call.Method != "port.getHtml" {
		t.Fatalf("the host got %+v", call)
	}
	if call.RemotePeer != "guest-instance" {
		t.Fatalf("remote peer %q: the transport's authenticated peer must win over what the guest wrote", call.RemotePeer)
	}
	if call.RemoteAttest != Attest(testAttestKey, "guest-instance") {
		t.Fatalf("the peer id was not attested with the stdin key")
	}
	if call.Credential != "" {
		t.Fatalf("a credential crossed from a remote caller: %q", call.Credential)
	}
	if !call.Streamable || !strings.HasPrefix(call.SenderID, "remote-") {
		t.Fatalf("a remote caller must be streamable and addressed as a session: %+v", call)
	}

	// A stream frame then the response, routed back down the session in order.
	hostSend(Envelope{Type: "stream", TargetID: call.SenderID, CallID: "c1", Payload: json.RawMessage(`{"n":1}`)})
	hostSend(Envelope{Type: "response", TargetID: call.SenderID, CallID: "c1", Payload: json.RawMessage(`{"n":2}`)})
	if e := guestRecv(t, ctx, guest); e.Type != "stream" || e.CallID != "c1" {
		t.Fatalf("first frame %+v", e)
	}
	if e := guestRecv(t, ctx, guest); e.Type != "response" || e.CallID != "c1" {
		t.Fatalf("second frame %+v", e)
	}
}

func TestALocalCallerCannotClaimToBeRemote(t *testing.T) {
	ctx, host, _, _, url := remoteWorld(t, testAttestKey)
	local := identified(t, ctx, url, "local-caller", false)
	defer local.CloseNow()
	sendEnvelope(t, ctx, local, Envelope{Type: "call", Method: "ports.list", CallID: "l1",
		RemotePeer: "guest-instance", RemoteAttest: Attest(testAttestKey, "guest-instance")})
	call := host()
	if call.RemotePeer != "" || call.RemoteAttest != "" {
		t.Fatalf("a /ws caller's remote fields reached the host: %q %q", call.RemotePeer, call.RemoteAttest)
	}
}

func TestWithNoAttestationKeyNoRemoteCallerIsServed(t *testing.T) {
	ctx, _, _, guest, _ := remoteWorld(t, "")
	guestSend(t, ctx, guest, Envelope{Type: "call", Method: "ports.list", CallID: "n1"})
	if e := guestRecv(t, ctx, guest); e.Type != "error" || e.Code != CodeTransportFailed {
		t.Fatalf("expected a refusal, got %+v", e)
	}
}

// The app verifies what the gateway signs, so both compute this MAC. The vector was computed outside
// both (Python's hmac) and is checked by InstanceIdentityTests too, so neither side can drift alone.
const attestVector = "T2rMErKZVK7NvW0X3uCUcu0ulJ8bgLHakoL7VQ0QRYo="

func TestTheAttestationMatchesTheSharedVector(t *testing.T) {
	if got := Attest(testAttestKey, "guest-instance"); got != attestVector {
		t.Fatalf("Attest = %q, want %q (the app checks the same vector)", got, attestVector)
	}
}

func TestTheAttestationBindsKeyAndPeer(t *testing.T) {
	a := Attest("k", "peer-a")
	if a == Attest("k", "peer-b") || a == Attest("other-key", "peer-a") || a != Attest("k", "peer-a") {
		t.Fatalf("the MAC must change with the peer and the key, and only with them")
	}
}

func TestMessagesSplitIntoFramesAndReassemble(t *testing.T) {
	msg := bytes.Repeat([]byte("port html "), 300_000) // 3 MB
	frames := SplitMessage(msg, 65535)
	if len(frames) < 2 {
		t.Fatalf("a 3 MB message fit in one frame")
	}
	r := NewReassembler(MaxMessage)
	var got []byte
	for i, f := range frames {
		if len(f) > 65535 {
			t.Fatalf("frame %d is %d bytes, over the limit", i, len(f))
		}
		out, err := r.Add(f)
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if out != nil && i != len(frames)-1 {
			t.Fatalf("a message completed early, at frame %d", i)
		}
		got = out
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("reassembled %d bytes, want %d", len(got), len(msg))
	}
	if one := SplitMessage(nil, 65535); len(one) != 1 {
		t.Fatalf("an empty message is one frame")
	}
}

func TestAMessagePastTheCapIsRefused(t *testing.T) {
	r := NewReassembler(1000)
	for _, f := range SplitMessage(make([]byte, 5000), 512) {
		if _, err := r.Add(f); err == ErrMessageTooLarge {
			return
		}
	}
	t.Fatalf("a message past the cap was reassembled")
}
