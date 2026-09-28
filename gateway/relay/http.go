package relay

import (
	"net/http"
	"time"
)

// NewHTTPServer is the listener for the relay and the invite page (GW-12). Their connections are
// long-lived WebSockets, so there is no read or write timeout, but request headers must arrive
// promptly: without ReadHeaderTimeout a client sending them slowly holds a connection indefinitely.
func NewHTTPServer(addr string, h http.Handler) *http.Server {
	return &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 10 * time.Second}
}
