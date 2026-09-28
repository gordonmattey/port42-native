package main

import (
	"net"
	"net/http"
)

// loopbackOnly guards a gateway that listens on loopback against the two ways a web page reaches it
// (GW-05).
//
//   - A page's own requests: browsers always send `Origin` on a WebSocket handshake and on a
//     cross-origin POST, while the app, the CLI and Node peers send none. Any Origin is refused.
//   - DNS rebinding: a page on attacker.example re-resolves its own name to 127.0.0.1 and becomes
//     "same origin" with the gateway. Its requests still carry `Host: attacker.example`, so only a
//     loopback Host is accepted.
//
// Browser guests reach this machine through a relay (remote.go), never through the loopback door, so
// nothing legitimate is refused. A gateway on a network address keeps the WebSocket library's
// same-origin check instead, since its Host is whatever name the operator publishes.
func loopbackOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Origin") != "" {
			http.Error(w, "browser origins are not accepted", http.StatusForbidden)
			return
		}
		if !isLoopbackHost(r.Host) {
			http.Error(w, "host not accepted", http.StatusMisdirectedRequest)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// isLoopbackHost reports whether a Host header names this machine by a loopback name or address.
func isLoopbackHost(hostport string) bool {
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		host = hostport // Host without a port
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// isLoopbackAddr reports whether a listen address only accepts connections from this machine. An empty
// host (":4242") listens on every interface, so it is not loopback.
func isLoopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil || host == "" {
		return false
	}
	return isLoopbackHost(host)
}
