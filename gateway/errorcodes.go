package main

// The gateway's own error codes.
//
// **THE APP OWNS THIS LIST.** Every constant here must exist as a `BridgeErrorCode` case in
// `Sources/Port42Lib/Services/BridgeErrorCode.swift`, which is the single place codes are declared
// and the only thing the published documentation renders from. That is enforced from the Swift side
// by a gate that scans this file, so a code invented here without a case there fails the suite.
//
// Why they exist: these failures used to be bare English ("no host available", "host is offline"),
// which a caller cannot branch on. They are also the FIRST thing a remote caller meets, before any
// error the app itself produces, so leaving them untyped would have put an untyped edge in front of
// a typed surface.
const (
	// Nothing is registered as the host: Port42 is not running, or not connected to this gateway.
	CodeNoHost = "no_host"
	// A host was registered and its connection is gone. Kept apart from CodeNoHost because the
	// repair differs: this one usually fixes itself, so retry rather than go looking for the app.
	CodeHostOffline = "host_offline"
	// The gateway reached the host and the send failed.
	CodeTransportFailed = "transport_failed"
	// The host did not answer inside the call timeout.
	CodeTimedOut = "timed_out"
	// The request omitted something required (the HTTP door's own bad-request case).
	CodeMissingArg = "missing_arg"
	// An envelope type the gateway has no handler for.
	CodeUnknownMethod = "unknown_method"
)

// DELIBERATELY NOT CODED: the channel and message path.
//
// "rate limit exceeded", "channel_id too long", "not a member of this channel", "too many active
// tokens", "message requires channel_id" are all on the MESSAGING protocol, which slice-02 leaves
// untouched by BR1 and which no bridge caller meets. Typing them would mean either inventing codes
// the app's enum does not have, or bending messaging failures into names built for the RPC surface.
// The line is drawn at what a CALLER can act on, which is what Part 0's ERRORS row is about.
