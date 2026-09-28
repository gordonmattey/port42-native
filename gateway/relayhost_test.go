package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/port42/gateway/relay"
)

// The app's commands arrive one per line on its private pipe; anything else is ignored, and the
// reader returns when the pipe closes.
func TestReadControlFollowsTheAppsCommands(t *testing.T) {
	var got []bool
	readControl(bufio.NewReader(strings.NewReader("relay-host on\nsomething else\nrelay-host off\nrelay-host on")),
		func(on bool) { got = append(got, on) })
	if len(got) != 3 || !got[0] || got[1] || !got[2] {
		t.Fatalf("commands followed: %v, want [true false true]", got)
	}
}

// On starts the host loops once however often it is said; off stops them and says the relays are down.
func TestRelayHostSwitchesRegistration(t *testing.T) {
	var mu sync.Mutex
	runs := 0
	var live context.Context
	var down []string
	h := &relayHost{
		run:    func(ctx context.Context) { mu.Lock(); runs++; live = ctx; mu.Unlock() },
		relays: []string{"wss://r/v1"},
		setState: func(r string, up bool) {
			if !up {
				down = append(down, r)
			}
		},
	}
	if h.hosting() {
		t.Fatal("hosting before the app asked (GW-16: every install registered at launch)")
	}
	h.set(true)
	h.set(true)
	if runs != 1 || !h.hosting() {
		t.Fatalf("runs %d hosting %v, want one run and hosting", runs, h.hosting())
	}
	h.set(false)
	if live.Err() == nil || h.hosting() || len(down) != 1 {
		t.Fatalf("off did not stop the loops (ctx %v) or say the relay is down (%v)", live.Err(), down)
	}
	h.set(true)
	if runs != 2 {
		t.Fatalf("on after off did not start the loops again: %d runs", runs)
	}
	h.set(false)
}

// End to end against a real relay: another instance cannot reach this one until it hosts, can while
// it does, and cannot once it stops.
func TestAnInstanceIsReachableOnlyWhileItHosts(t *testing.T) {
	rsrv := httptest.NewServer(relay.NewServer(relay.DefaultLimits).Handler())
	defer rsrv.Close()
	relayURL := "ws" + strings.TrimPrefix(rsrv.URL, "http") + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	_, hostKey, _ := ed25519.GenerateKey(rand.Reader)
	here := relay.NewTransport(hostKey, []string{relayURL})
	h := &relayHost{run: here.Run, relays: []string{relayURL}, setState: func(string, bool) {}}
	_, guestKey, _ := ed25519.GenerateKey(rand.Reader)
	guest := relay.NewTransport(guestKey, []string{relayURL})

	offline := func(err error) bool {
		var r *relay.Refusal
		return errors.As(err, &r) && r.Code == relay.CodeHostOffline
	}
	// Reachable within a few seconds, or not.
	reach := func() error {
		var err error
		for i := 0; i < 100; i++ {
			var s interface{ Close() error }
			ss, e := guest.Dial(ctx, here.PeerID())
			if e == nil {
				s = ss
				s.Close()
				return nil
			}
			err = e
			if !offline(e) {
				return e
			}
			time.Sleep(20 * time.Millisecond)
		}
		return err
	}

	if _, err := guest.Dial(ctx, here.PeerID()); !offline(err) {
		t.Fatalf("reachable before hosting: %v", err)
	}
	h.set(true)
	if err := reach(); err != nil {
		t.Fatalf("not reachable while hosting: %v", err)
	}
	h.set(false)
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, err := guest.Dial(ctx, here.PeerID())
		if offline(err) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("still reachable after hosting stopped: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
