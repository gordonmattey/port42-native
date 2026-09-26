package main

import "errors"

// Splitting a message into frames a transport can carry (nautilus Phase 4, 4.3;
// docs/design-phase4-relay.md "Inside the session").
//
// A Noise transport message holds at most 65,535 bytes and a port's HTML can be megabytes, so a
// message is sent as a run of frames, each a one-byte header and a piece of the message. The header
// says whether more follows. The receiver refuses a message that grows past a cap, so a peer cannot
// make this process hold an unbounded message in memory.

const (
	frameMore byte = 1
	frameLast byte = 0
	// MaxMessage is the largest message a receiver will reassemble.
	MaxMessage = 8 << 20
)

// ErrMessageTooLarge is returned when a message grows past MaxMessage.
var ErrMessageTooLarge = errors.New("message too large")

// SplitMessage cuts msg into frames of at most maxFrame bytes, header included. An empty message is
// one frame.
func SplitMessage(msg []byte, maxFrame int) [][]byte {
	body := maxFrame - 1
	if body < 1 {
		body = 1
	}
	var frames [][]byte
	for {
		n := len(msg)
		if n > body {
			n = body
		}
		header := frameLast
		if len(msg) > n {
			header = frameMore
		}
		frame := make([]byte, 0, n+1)
		frame = append(frame, header)
		frame = append(frame, msg[:n]...)
		frames = append(frames, frame)
		msg = msg[n:]
		if header == frameLast {
			return frames
		}
	}
}

// Reassembler collects frames back into messages.
type Reassembler struct {
	buf []byte
	max int
}

func NewReassembler(max int) *Reassembler { return &Reassembler{max: max} }

// Add takes one frame. It returns the whole message when the frame was the last of one, nil while
// more is expected, and an error for an empty frame or a message past the cap (after which the
// session should be closed).
func (r *Reassembler) Add(frame []byte) ([]byte, error) {
	if len(frame) == 0 {
		return nil, errors.New("empty frame")
	}
	if len(r.buf)+len(frame)-1 > r.max {
		r.buf = nil
		return nil, ErrMessageTooLarge
	}
	r.buf = append(r.buf, frame[1:]...)
	if frame[0] == frameMore {
		return nil, nil
	}
	msg := r.buf
	r.buf = nil
	return msg, nil
}
