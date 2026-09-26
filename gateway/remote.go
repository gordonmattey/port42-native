package main

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/port42/gateway/transport"
)

// THE REMOTE DOOR (nautilus Phase 4, step 4.3).
//
// A caller on another machine arrives as a Session from a Transport. Its calls go to the host exactly
// as a `/ws` caller's do, with two differences: no credential rides along (no token crosses the
// internet), and the gateway stamps the peer id the transport authenticated, with an HMAC over it.
//
// **The app never trusts the peer id without that HMAC.** Its key is a per-spawn secret the app hands
// over on stdin as the THIRD line, after the host credential and the peer key, and it never travels on
// any socket. The host credential could not serve: the app sends that over the socket in `identify`,
// so a process squatting the gateway's port would learn it and could name any peer it liked.
//
// Nothing arriving on `/ws` or `/call` can carry these fields: they are stripped at the door, so a
// local caller cannot claim to be remote.

// attestLabel separates this MAC from any other use of the key.
const attestLabel = "port42-remote-v1|"

// ReadAttestKey takes the third handover line. Empty when absent, and then no remote call is served.
func ReadAttestKey(r *bufio.Reader) string {
	line, err := r.ReadString('\n')
	if err != nil && line == "" {
		return ""
	}
	return strings.TrimRight(line, "\r\n")
}

// Attest is the MAC the app checks before it forms a remote principal. The app computes the same.
func Attest(key, peer string) string {
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte(attestLabel + peer))
	return base64.StdEncoding.EncodeToString(m.Sum(nil))
}

// SetAttestKey is called once, from the watch-parent goroutine, after the peer identity.
func (g *Gateway) SetAttestKey(k string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.attestKey = k
}

// remoteConn is one remote session, addressed by the id the host replies to.
type remoteConn struct {
	s      transport.Session
	sendMu sync.Mutex
	rateMu sync.Mutex
	times  []time.Time
}

func (c *remoteConn) rateOK() bool {
	c.rateMu.Lock()
	defer c.rateMu.Unlock()
	now := time.Now()
	cutoff := now.Add(-time.Second)
	i := 0
	for i < len(c.times) && c.times[i].Before(cutoff) {
		i++
	}
	c.times = c.times[i:]
	if len(c.times) >= rateLimitPerSec {
		return false
	}
	c.times = append(c.times, now)
	return true
}

func (c *remoteConn) send(ctx context.Context, env Envelope) error {
	data, err := json.Marshal(env)
	if err != nil {
		return err
	}
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	return c.s.Send(ctx, data)
}

// ServeRemote accepts sessions from a transport until ctx ends, and runs each as a caller.
func (g *Gateway) ServeRemote(ctx context.Context, t transport.Transport) {
	for {
		s, err := t.Accept(ctx)
		if err != nil {
			return
		}
		go g.serveSession(ctx, s)
	}
}

func (g *Gateway) serveSession(ctx context.Context, s transport.Session) {
	var b [8]byte
	rand.Read(b[:])
	id := "remote-" + hex.EncodeToString(b[:])
	c := &remoteConn{s: s}
	g.mu.Lock()
	if g.remotes == nil {
		g.remotes = map[string]*remoteConn{}
	}
	g.remotes[id] = c
	g.mu.Unlock()
	defer func() {
		g.mu.Lock()
		delete(g.remotes, id)
		g.mu.Unlock()
		s.Close()
	}()
	peer := s.RemotePeer()
	log.Printf("[gateway] remote session %s from peer %s", id, peer)

	for {
		msg, err := s.Recv(ctx)
		if err != nil {
			return
		}
		if !c.rateOK() {
			c.send(ctx, Envelope{Type: "error", Error: "rate limit exceeded"})
			continue
		}
		var env Envelope
		if err := json.Unmarshal(msg, &env); err != nil {
			continue
		}
		if env.Type != "call" {
			c.send(ctx, Envelope{Type: "error", Error: "unknown type: " + env.Type,
				Code: CodeUnknownMethod, CallID: env.CallID})
			continue
		}
		g.routeRemoteCall(ctx, c, id, peer, env)
	}
}

func (g *Gateway) routeRemoteCall(ctx context.Context, c *remoteConn, id, peer string, env Envelope) {
	g.mu.RLock()
	hostID, key := g.globalHostID, g.attestKey
	hostPeer, online := g.peers[hostID]
	g.mu.RUnlock()
	switch {
	case hostID == "":
		c.send(ctx, Envelope{Type: "error", Error: "no host available", Code: CodeNoHost, CallID: env.CallID})
		return
	case !online:
		c.send(ctx, Envelope{Type: "error", Error: "host is offline", Code: CodeHostOffline, CallID: env.CallID})
		return
	case key == "":
		// A gateway with no attestation key cannot vouch for anyone, so it serves no remote caller.
		c.send(ctx, Envelope{Type: "error", Error: "this gateway does not serve remote callers",
			Code: CodeTransportFailed, CallID: env.CallID})
		return
	}
	env.SenderID = id
	env.Streamable = true
	env.Credential = ""
	env.RemotePeer = peer
	env.RemoteAttest = Attest(key, peer)
	if err := hostPeer.Send(ctx, env); err != nil {
		c.send(ctx, Envelope{Type: "error", Error: "failed to reach host", Code: CodeTransportFailed, CallID: env.CallID})
	}
}

// deliverRemote hands a host frame to a remote session, if the target is one.
func (g *Gateway) deliverRemote(ctx context.Context, target string, env Envelope) bool {
	g.mu.RLock()
	c, ok := g.remotes[target]
	g.mu.RUnlock()
	if !ok {
		return false
	}
	// The host's local connection id is this machine's business, not the guest's.
	env.PeerID = ""
	if err := c.send(ctx, env); err != nil {
		log.Printf("[gateway] failed to deliver to %s: %v", target, err)
	}
	return true
}
