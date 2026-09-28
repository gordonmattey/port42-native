package main

import (
	"bufio"
	"context"
	"strings"
	"sync"
)

// relayHost switches this instance's registration on its relays (GW-16, GM 2026-09-28). Every install
// used to register at launch and stay registered, reachable by anyone who learned its peer id and
// holding a connection to the public relay whether or not it shared anything. Now it is registered only
// while the app says so: while a port is shared or an invite could still be redeemed. Reaching someone
// else's port dials out as a guest and does not need this.
type relayHost struct {
	mu       sync.Mutex
	run      func(ctx context.Context) // starts the host loops until ctx ends (relay.Transport.Run)
	relays   []string
	setState func(relay string, up bool)
	cancel   context.CancelFunc
}

// set turns registration on or off. Repeating the current state does nothing.
func (h *relayHost) set(on bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	switch {
	case on && h.cancel == nil:
		ctx, cancel := context.WithCancel(context.Background())
		h.cancel = cancel
		h.run(ctx)
	case !on && h.cancel != nil:
		h.cancel()
		h.cancel = nil
		for _, r := range h.relays {
			h.setState(r, false)
		}
	}
}

// hosting reports whether registration is on.
func (h *relayHost) hosting() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.cancel != nil
}

// readControl reads the app's commands from the rest of its handover pipe, one per line, until the
// pipe closes (the app is gone). The pipe is private to the app, so no other process can send these.
func readControl(r *bufio.Reader, hostRelay func(on bool)) {
	for {
		line, err := r.ReadString('\n')
		switch strings.TrimSpace(line) {
		case "relay-host on":
			hostRelay(true)
		case "relay-host off":
			hostRelay(false)
		}
		if err != nil {
			return // io.EOF: the app closed the pipe
		}
	}
}
