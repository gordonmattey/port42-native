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
	// The caller sent more than the gateway takes in a second; the frame was dropped. Slow down and
	// send it again. The host is never limited (its frames answer calls).
	CodeRateLimited = "rate_limited"
)

// The channel and message path that once sat beside these ("not a member of this channel", "too many
// active tokens") went with the hub in nautilus Phase 0 step 3. "rate limit exceeded" was left uncoded
// as a transport condition; it is coded now (2026-09-27), because a caller cannot tell a refusal it
// can retry from any other without one.
