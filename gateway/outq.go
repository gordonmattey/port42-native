package main

import (
	"context"
	"errors"
	"log"
	"sync"
	"time"
)

// outq is one destination's outgoing frames, written in order by a goroutine of its own, so a destination that
// is slow to read holds up only itself.
//
// Before it, the host's read loop wrote each answer and each event straight to its destination: to a local
// caller's WebSocket, or through the relay to another machine. A caller that stopped reading, or a relay that
// was slow, blocked that write, and with it the loop that reads every other answer from the app. Every call on
// the machine then waited, `whoami` included, with the app idle (the 20 second freezes on Dev6, 2026-10-02).
type outq struct {
	frames chan []byte
	done   chan struct{}
	once   sync.Once
	write  func(context.Context, []byte) error
	fail   func(reason string)
	// Set once, at creation: a frame's write timeout.
	timeout time.Duration
}

// outqLen is how many frames a destination may fall behind before it is dropped (a caller) or its senders wait
// (the app). outqWriteTimeout is how long one frame may take to write before the destination is dropped.
var (
	outqLen          = 512
	outqWriteTimeout = 10 * time.Second
)

var (
	errOutqClosed = errors.New("connection closed")
	errOutqFull   = errors.New("too slow to read: dropped")
)

func newOutq(write func(context.Context, []byte) error, fail func(reason string)) *outq {
	q := &outq{frames: make(chan []byte, outqLen), done: make(chan struct{}), write: write, fail: fail,
		timeout: outqWriteTimeout}
	go q.run()
	return q
}

func (q *outq) run() {
	for {
		select {
		case data := <-q.frames:
			ctx, cancel := context.WithTimeout(context.Background(), q.timeout)
			began := time.Now()
			err := q.write(ctx, data)
			cancel()
			if took := time.Since(began); took > time.Second {
				log.Printf("[gateway] a frame took %v to write (%d behind)", took.Round(time.Millisecond), len(q.frames))
			}
			if err != nil {
				q.stop("write failed: " + err.Error())
				return
			}
		case <-q.done:
			return
		}
	}
}

// stop ends the queue once, and tells the destination's owner why, off the caller's goroutine: closing a
// connection that does not read can itself take a while.
func (q *outq) stop(reason string) {
	q.once.Do(func() {
		close(q.done)
		if q.fail != nil {
			go q.fail(reason)
		}
	})
}

// end stops the queue when its destination has gone: nothing to tell anyone.
func (q *outq) end() { q.once.Do(func() { close(q.done) }) }

// put queues a frame. `wait`: block until there is room, for the app, whose frames are calls people are waiting
// on; otherwise a destination that has fallen outqLen frames behind is dropped rather than waited for.
func (q *outq) put(ctx context.Context, data []byte, wait bool) error {
	select {
	case <-q.done:
		return errOutqClosed
	default:
	}
	if wait {
		select {
		case q.frames <- data:
			return nil
		case <-q.done:
			return errOutqClosed
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	select {
	case q.frames <- data:
		return nil
	case <-q.done:
		return errOutqClosed
	default:
		q.stop("fell too far behind")
		return errOutqFull
	}
}
