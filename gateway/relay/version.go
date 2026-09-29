package relay

// Commit is the git commit this server was built from, set at build time
// (-ldflags "-X github.com/port42/gateway/relay.Commit=<sha>"; the images take it as the COMMIT build
// argument). The relay and tele serve it at /version, so a deploy can check that what answers is what
// it just built: /health alone cannot tell the old build from the new one.
var Commit = "unknown"
