#!/bin/bash
# Checks port42's own relay1 and tele after a deploy (docs/run-a-relay.md, "For maintainers").
#
#   scripts/check-live.sh [commit or tag]     # default: HEAD; e.g. relay-v1.0.2
#
# Both must answer /health, both must serve the commit at /version, and tele must serve the guest
# files exactly as that commit holds them. Runs every check, then exits non-zero if any failed.
set -u
cd "$(dirname "$0")/.."

want=$(git rev-parse "${1:-HEAD}^{commit}") || exit 1
RELAY=${RELAY:-https://relay1.port42.ai}
TELE=${TELE:-https://tele.port42.ai}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
fail=0

check() { # name, ok?, detail
	if [ "$2" = 0 ]; then echo "ok    $1"; else echo "FAIL  $1: $3"; fail=1; fi
}

for svc in "relay $RELAY" "tele $TELE"; do
	set -- $svc
	health=$(curl -s -m 15 "$2/health")
	[ "$health" = ok ]; check "$1 /health" $? "got '$health'"
	live=$(curl -s -m 15 "$2/version")
	[ "$live" = "$want" ]; check "$1 /version is ${want:0:7}" $? "it serves '${live:0:40}'"
done

for pair in "/ guest/invite.html" "/frame.html guest/frame.html" "/dist/port42-guest.js guest/dist/port42-guest.js"; do
	set -- $pair
	code=$(curl -s -m 15 -o "$tmp" -w '%{http_code}' "$TELE$1")
	[ "$code" = 200 ] && git show "$want:$2" | cmp -s - "$tmp"
	check "tele $1 matches $2" $? "HTTP $code, or it differs from $2 at ${want:0:7}"
done

exit $fail
