package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/port42/gateway/relay"
)

// The browser lane's interop gate (nautilus Phase 4, 4.7): the guest runtime a browser runs
// (guest/src), in Node, reaches a host through a real relay, speaks the same Noise IK handshake and
// chunking as the Go peers, and makes calls the host's app answers: a redeem, a read, a refused write
// retried with `current`, a streamed event, and a message larger than one Noise frame each way.
func TestABrowserGuestReachesAHostThroughTheRelay(t *testing.T) {
	node, script := guestRuntime(t)
	rsrv := httptest.NewServer(relay.NewServer(relay.DefaultLimits).Handler())
	defer rsrv.Close()
	relayURL := "ws" + strings.TrimPrefix(rsrv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	a := newInstance(t, ctx)
	a.app.SetReadLimit(2 << 20) // what the app's own connection takes (GatewayDoor's maximumMessageSize)
	link := relay.NewTransport(a.gw.peerKey(), []string{relayURL})
	link.Run(ctx)
	go a.gw.ServeRemote(ctx, link)
	time.Sleep(150 * time.Millisecond)

	// The host's app: answer each call from the guest as Port42 would.
	var guest string
	go func() {
		for {
			var call Envelope
			_, data, err := a.app.Read(ctx)
			if err != nil || json.Unmarshal(data, &call) != nil {
				return
			}
			if call.Type != "call" {
				continue
			}
			if call.RemoteAttest != Attest(testAttestKey, call.RemotePeer) {
				t.Errorf("a call from the browser was not attested: %+v", call)
			}
			guest = call.RemotePeer
			var args map[string]any
			json.Unmarshal(call.Args, &args)
			answer := func(typ string, content any) {
				c, _ := json.Marshal(content)
				p, _ := json.Marshal(map[string]string{"senderName": "host", "senderType": "host", "content": string(c)})
				sendEnvelope(t, ctx, a.app, Envelope{Type: typ, TargetID: call.SenderID, CallID: call.CallID, Payload: p})
			}
			switch call.Method {
			case "invite.redeem":
				answer("response", map[string]any{"port": "P", "title": "chart", "rights": []string{"see", "use"}})
			case "port.getHtml":
				answer("response", "<p>from the host</p>"+stringArg(args, "echo"))
			case "port.push":
				if args["token"] == "t:1" {
					answer("response", map[string]any{"code": "stale_write", "error": "moved", "current": "t:2"})
				} else {
					answer("response", map[string]any{"ok": true, "token": "t:3"})
				}
			case "port.subscribe":
				answer("stream", map[string]any{"kind": "push", "payload": map[string]any{"n": 9}})
			}
		}
	}()

	lines := runGuest(t, ctx, node, script, relayURL, a.id, "")
	want := map[string]func(map[string]any) bool{
		"redeem":  func(m map[string]any) bool { return m["out"].(map[string]any)["port"] == "P" },
		"getHtml": func(m map[string]any) bool { return m["out"] == "<p>from the host</p>" },
		"refused": func(m map[string]any) bool { return m["code"] == "stale_write" && m["current"] == "t:2" },
		"push":    func(m map[string]any) bool { return m["out"].(map[string]any)["token"] == "t:3" },
		"event":   func(m map[string]any) bool { return m["event"].(map[string]any)["kind"] == "push" },
		"big":     func(m map[string]any) bool { return m["out"] == float64(len("<p>from the host</p>")+200_000) },
	}
	for step, ok := range want {
		m, got := lines[step]
		if !got {
			t.Fatalf("the browser guest never reached %q; it said %v", step, lines)
		}
		if !ok(m) {
			t.Errorf("%s: %v", step, m)
		}
	}
	if me := lines["me"]["id"]; guest != me {
		t.Errorf("the host saw the guest as %q, not its own id %v", guest, me)
	}
}

// A browser guest that asks for an instance not on the relay is told it is offline, and nothing
// else happens.
func TestABrowserGuestIsToldTheHostIsOffline(t *testing.T) {
	node, script := guestRuntime(t)
	rsrv := httptest.NewServer(relay.NewServer(relay.DefaultLimits).Handler())
	defer rsrv.Close()
	relayURL := "ws" + strings.TrimPrefix(rsrv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	nobody := newInstance(t, ctx) // never registers on the relay
	lines := runGuest(t, ctx, node, script, relayURL, nobody.id, "")
	if f := lines["failed"]; f == nil || f["code"] != "host_offline" {
		t.Fatalf("want host_offline, got %v", lines)
	}
}

// A guest whose handshake the host cannot read (here, the wrong protocol version) is told the host
// refused it, not that it is offline.
func TestABrowserGuestTheHostCannotReadIsRefused(t *testing.T) {
	node, script := guestRuntime(t)
	rsrv := httptest.NewServer(relay.NewServer(relay.DefaultLimits).Handler())
	defer rsrv.Close()
	relayURL := "ws" + strings.TrimPrefix(rsrv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	a := newInstance(t, ctx)
	link := relay.NewTransport(a.gw.peerKey(), []string{relayURL})
	link.Run(ctx)
	go a.gw.ServeRemote(ctx, link)
	time.Sleep(150 * time.Millisecond)
	lines := runGuest(t, ctx, node, script, relayURL, a.id, "wrong-prologue")
	if f := lines["failed"]; f == nil || f["code"] != "refused" {
		t.Fatalf("want refused, got %v", lines)
	}
}

// The invite page's own tests (guest/test/*.test.mjs, in a browser DOM) run with the gateway's, so
// `go test ./...` covers the whole browser lane.
func TestTheInvitePage(t *testing.T) {
	node, _ := guestRuntime(t)
	root, _ := filepath.Abs("../guest")
	files, _ := filepath.Glob(filepath.Join(root, "test", "*.test.mjs"))
	if len(files) == 0 {
		t.Fatal("no invite page tests found")
	}
	cmd := exec.Command(node, append([]string{"--test"}, files...)...)
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("the invite page's tests failed: %v\n%s", err, out)
	}
}

func stringArg(args map[string]any, k string) string { s, _ := args[k].(string); return s }

// guestRuntime finds node and the guest's end-to-end script. With no node or no installed guest
// libraries the gate cannot run; it says so rather than passing.
func guestRuntime(t *testing.T) (string, string) {
	t.Helper()
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not installed; the browser guest gate needs it")
	}
	root, _ := filepath.Abs("../guest")
	if _, err := os.Stat(filepath.Join(root, "node_modules", "@noble", "curves")); err != nil {
		t.Fatalf("the guest's libraries are not installed: run npm install in guest/")
	}
	return node, filepath.Join(root, "test", "e2e-guest.mjs")
}

func runGuest(t *testing.T, ctx context.Context, node, script, relayURL, host, mode string) map[string]map[string]any {
	t.Helper()
	cmd := exec.CommandContext(ctx, node, script, relayURL, host, mode)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("the guest runtime failed: %v\n%s", err, out)
	}
	lines := map[string]map[string]any{}
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		var m map[string]any
		if json.Unmarshal(sc.Bytes(), &m) == nil {
			if step, _ := m["step"].(string); step != "" {
				lines[step] = m
			}
		}
	}
	return lines
}
