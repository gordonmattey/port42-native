package main

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/port42/gateway/relay"
	"github.com/port42/gateway/transport"
)

// OUTBOUND CALLS (nautilus Phase 4, step 4.6): this instance calling a port on ANOTHER instance.
//
// The app sends a `remote_call` on its host connection naming the other instance's peer id, the relays
// it can be reached through (from the invite), and an ordinary call. The gateway dials that peer as a
// guest (Noise, this instance's key), keeps the session for later calls, sends the call, and hands
// every `response`, `stream` and `error` for that call id back to the app. The other instance sees an
// ordinary remote caller, this instance's key, and applies its own rights to it.

type outSession struct {
	s      transport.Session
	sendMu sync.Mutex
}

type outbound struct {
	mu       sync.Mutex
	sessions map[string]*outSession // by peer id
	dialing  map[string]chan struct{}
	pending  map[string]string // call id -> peer id, for failing calls when a session ends
}

func (g *Gateway) out() *outbound {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.outbound == nil {
		g.outbound = &outbound{sessions: map[string]*outSession{}, dialing: map[string]chan struct{}{},
			pending: map[string]string{}}
	}
	return g.outbound
}

// dialer builds the transport used to reach other instances. Replaced in tests.
var newDialer = func(key ed25519.PrivateKey, relays []string) transport.Transport {
	return relay.NewTransport(key, relays)
}

// handleRemoteCall runs one outbound call for the host.
func (g *Gateway) handleRemoteCall(ctx context.Context, host *Peer, env Envelope) {
	fail := func(code, msg string) {
		host.Send(ctx, Envelope{Type: "error", CallID: env.CallID, Code: code, Error: msg})
	}
	key := g.peerKey()
	if key == nil {
		fail(CodeTransportFailed, "this instance has no key, so it cannot reach another")
		return
	}
	if env.ToPeer == "" || len(env.Relays) == 0 {
		fail(CodeMissingArg, "a remote call needs the peer and its relays")
		return
	}
	o := g.out()
	sess, err := o.session(ctx, env.ToPeer, func() (transport.Session, error) {
		dctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		return newDialer(key, env.Relays).Dial(dctx, env.ToPeer)
	}, func(s transport.Session) { go g.readOutbound(host, env.ToPeer, s) })
	if err != nil {
		var r *relay.Refusal
		if errors.As(err, &r) && r.Code == relay.CodeHostOffline {
			fail(CodeHostOffline, "that instance is not connected to its relay")
			return
		}
		fail(CodeTransportFailed, "could not reach that instance: "+err.Error())
		return
	}
	call := Envelope{Type: "call", Method: env.Method, Args: env.Args, CallID: env.CallID, Actor: env.Actor}
	b, _ := json.Marshal(call)
	o.mu.Lock()
	o.pending[env.CallID] = env.ToPeer
	o.mu.Unlock()
	sess.sendMu.Lock()
	err = sess.s.Send(ctx, b)
	sess.sendMu.Unlock()
	if err != nil {
		o.drop(env.ToPeer, sess)
		fail(CodeTransportFailed, "the session to that instance failed: "+err.Error())
	}
}

// session returns the live session to peer, dialling once if there is none (concurrent callers wait
// for the same dial).
func (o *outbound) session(ctx context.Context, peer string, dial func() (transport.Session, error),
	started func(transport.Session)) (*outSession, error) {
	for {
		o.mu.Lock()
		if s := o.sessions[peer]; s != nil {
			o.mu.Unlock()
			return s, nil
		}
		if wait, ok := o.dialing[peer]; ok {
			o.mu.Unlock()
			select {
			case <-wait:
				continue
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		done := make(chan struct{})
		o.dialing[peer] = done
		o.mu.Unlock()

		s, err := dial()
		o.mu.Lock()
		delete(o.dialing, peer)
		var os *outSession
		if err == nil {
			os = &outSession{s: s}
			o.sessions[peer] = os
		}
		o.mu.Unlock()
		close(done)
		if err != nil {
			return nil, err
		}
		started(s)
		return os, nil
	}
}

func (o *outbound) drop(peer string, s *outSession) {
	o.mu.Lock()
	if o.sessions[peer] == s {
		delete(o.sessions, peer)
	}
	o.mu.Unlock()
	s.s.Close()
}

// readOutbound hands every frame from a session back to the host, and when the session ends, fails
// the calls still waiting on it so nothing hangs.
func (g *Gateway) readOutbound(host *Peer, peer string, s transport.Session) {
	ctx := context.Background()
	o := g.out()
	for {
		msg, err := s.Recv(ctx)
		if err != nil {
			break
		}
		var env Envelope
		if json.Unmarshal(msg, &env) != nil || env.CallID == "" {
			continue
		}
		switch env.Type {
		case "response", "error":
			o.mu.Lock()
			delete(o.pending, env.CallID)
			o.mu.Unlock()
		case "stream":
		default:
			continue
		}
		out := Envelope{Type: env.Type, CallID: env.CallID, Payload: env.Payload, Error: env.Error,
			Code: env.Code, RemotePeer: peer}
		if err := host.Send(ctx, out); err != nil {
			log.Printf("[gateway] could not hand a remote reply to the host: %v", err)
		}
	}
	o.mu.Lock()
	if cur := o.sessions[peer]; cur != nil && cur.s == s {
		delete(o.sessions, peer)
	}
	var orphaned []string
	for id, p := range o.pending {
		if p == peer {
			orphaned = append(orphaned, id)
			delete(o.pending, id)
		}
	}
	o.mu.Unlock()
	for _, id := range orphaned {
		host.Send(ctx, Envelope{Type: "error", CallID: id, Code: CodeHostOffline,
			Error: "the session to that instance ended"})
	}
}
