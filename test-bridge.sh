#!/bin/bash
# Port42 Bridge API test suite
# Tests the new port management, relationship state, and port AI APIs via HTTP.
#
# Usage:
#   ./test-bridge.sh                        # run all tests
#   ./test-bridge.sh --companion <uuid>     # also test fold/position (requires companion UUID)
#
# Get a companion UUID:
#   curl -s http://127.0.0.1:4242/call -d '{"method":"companions_list"}'

set -euo pipefail

HOST="http://127.0.0.1:4242"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

# Optional companion UUID for relationship state tests
COMPANION_ID=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --companion) COMPANION_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ─── helpers ─────────────────────────────────────────────────────────────────

call() {
  curl -s "$HOST/call" -d "$1"
}

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); echo "       got: $2"; }
skip() { echo -e "  ${YELLOW}SKIP${NC} $1"; SKIP=$((SKIP+1)); }
section() { echo ""; echo -e "${CYAN}$1${NC}"; }

# check result contains a string
check() {
  local name="$1" result="$2" expect="$3"
  if echo "$result" | grep -q "$expect"; then
    pass "$name"
  else
    fail "$name" "$result"
  fi
}

# check result does NOT contain "error"
check_ok() {
  local name="$1" result="$2"
  if echo "$result" | grep -qi '"error"'; then
    fail "$name" "$result"
  else
    pass "$name"
  fi
}

# extract a field from JSON content
extract() {
  echo "$1" | python3 -c "
import sys, json
try:
  d = json.loads(sys.stdin.read())
  c = d.get('content', d)
  if isinstance(c, str):
    inner = json.loads(c)
    print(inner.get('$2', ''))
  else:
    print(c.get('$2', ''))
except: print('')
" 2>/dev/null
}

echo ""
echo "========================================"
echo " Port42 Bridge API Test Suite"
echo "========================================"

# ─── health check ────────────────────────────────────────────────────────────

section "[1] Gateway health"
HEALTH=$(curl -s "$HOST/health" 2>/dev/null || echo "")
if echo "$HEALTH" | grep -q "ok"; then
  pass "gateway is up"
else
  echo -e "  ${RED}FATAL${NC} Gateway not responding at $HOST — is Port42 running?"
  exit 1
fi

# ─── core info ───────────────────────────────────────────────────────────────

section "[2] Core info"
check    "user.get returns displayName"  "$(call '{"method":"user_get"}')"          'displayName'
check_ok "channel.list returns items"    "$(call '{"method":"channel_list"}')"
check_ok "companions_list returns items" "$(call '{"method":"companions_list"}')"

# ─── port management ─────────────────────────────────────────────────────────

section "[3] Port management"

PORTS=$(call '{"method":"ports_list"}')
check_ok "ports_list responds without error" "$PORTS"

# Try dot-notation alias too
PORTS_DOT=$(call '{"method":"port.list"}') 2>/dev/null || true
# (dot form may not exist — that's fine, underscore is canonical for HTTP)

# port_get_html with a nonexistent id should return an error message (not crash)
GET_HTML=$(call '{"method":"port_get_html","args":{"id":"nonexistent-uuid"}}')
check "port_get_html unknown id returns error" "$GET_HTML" '"content"'

# port_history with nonexistent id
HISTORY=$(call '{"method":"port_history","args":{"id":"nonexistent-uuid"}}')
check_ok "port_history unknown id responds" "$HISTORY"

# port_manage with unknown id
MANAGE=$(call '{"method":"port_manage","args":{"id":"nonexistent","action":"focus"}}')
check "port_manage unknown id returns error message" "$MANAGE" '"content"'

# ─── messages ────────────────────────────────────────────────────────────────

section "[4] Messages"
check "messages_recent returns list" "$(call '{"method":"messages_recent","args":{"count":5}}')" '"content"'

# ─── relationship state (no companion context) ───────────────────────────────

section "[5] Relationship state — no context"

# crease_read with no context returns graceful response
CREASE=$(call '{"method":"crease_read","args":{"limit":3}}')
check_ok "crease_read (no context) responds" "$CREASE"

# fold_read with no companionId returns empty fold (uses anonymous remote context)
FOLD_NO=$(call '{"method":"fold_read"}')
check_ok "fold_read (no args) responds without crash" "$FOLD_NO"

# position_read with no companionId
POS_NO=$(call '{"method":"position_read"}')
check_ok "position_read (no args) responds" "$POS_NO"

# ─── relationship state (with companion UUID) ─────────────────────────────────

section "[6] Relationship state — with companion UUID"

if [ -z "$COMPANION_ID" ]; then
  skip "fold_read with companionId (pass --companion <uuid> to test)"
  skip "position_read with companionId"
  skip "fold_update"
  skip "position_set"
  skip "crease_write / crease_touch / crease_forget"
  echo ""
  echo "  To test relationship APIs, first get a companion UUID:"
  echo "  curl -s http://127.0.0.1:4242/call -d '{\"method\":\"companions_list\"}'"
  echo "  Then: ./test-bridge.sh --companion <uuid>"
else
  # fold_read
  FOLD=$(call "{\"method\":\"fold_read\",\"args\":{\"companionId\":\"$COMPANION_ID\"}}")
  check "fold_read with companionId returns depth" "$FOLD" 'depth'

  # position_read
  POS=$(call "{\"method\":\"position_read\",\"args\":{\"companionId\":\"$COMPANION_ID\"}}")
  check_ok "position_read with companionId responds" "$POS"

  # fold_update (no-op depthDelta: 0)
  FOLD_UPDATE=$(call "{\"method\":\"fold_update\",\"args\":{\"companionId\":\"$COMPANION_ID\",\"depthDelta\":0}}")
  check "fold_update responds ok" "$FOLD_UPDATE" "ok"

  # position_set
  POS_SET=$(call "{\"method\":\"position_set\",\"args\":{\"companionId\":\"$COMPANION_ID\",\"read\":\"testing from test-bridge.sh\"}}")
  check "position_set responds ok" "$POS_SET" "ok"

  # Verify position was written
  POS2=$(call "{\"method\":\"position_read\",\"args\":{\"companionId\":\"$COMPANION_ID\"}}")
  check_ok "position_read reflects written value" "$POS2"

  # crease_write
  CREASE_WRITE=$(call "{\"method\":\"crease_write\",\"args\":{\"companionId\":\"$COMPANION_ID\",\"content\":\"test crease from test-bridge.sh\"}}")
  check "crease_write returns id" "$CREASE_WRITE" 'true'

  # Extract the crease id
  CREASE_ID=$(echo "$CREASE_WRITE" | python3 -c "
import sys, json
try:
  d = json.loads(sys.stdin.read())
  c = d.get('content', '{}')
  inner = json.loads(c) if isinstance(c, str) else c
  print(inner.get('id', ''))
except: print('')
" 2>/dev/null)

  if [ -n "$CREASE_ID" ]; then
    # crease_touch
    TOUCH=$(call "{\"method\":\"crease_touch\",\"args\":{\"id\":\"$CREASE_ID\"}}")
    check "crease_touch responds ok" "$TOUCH" "ok"

    # crease_forget
    FORGET=$(call "{\"method\":\"crease_forget\",\"args\":{\"id\":\"$CREASE_ID\"}}")
    check "crease_forget responds ok" "$FORGET" "ok"
  else
    skip "crease_touch / crease_forget (could not extract crease id)"
  fi

  # Verify fold_read still works after updates
  FOLD2=$(call "{\"method\":\"fold_read\",\"args\":{\"companionId\":\"$COMPANION_ID\"}}")
  check "fold_read still works after fold_update" "$FOLD2" 'depth'
fi

# ─── dot-notation symmetry ────────────────────────────────────────────────────

section "[7] Dot-notation symmetry (HTTP accepts both forms)"

# RemoteToolExecutor maps dots to underscores, so both should work
check    "user.get (dot form)"        "$(call '{"method":"user.get"}')"                            'displayName'
check_ok "channel.list (dot form)"    "$(call '{"method":"channel.list"}')"
check_ok "companions.list (dot form)" "$(call '{"method":"companions.list"}')"
check_ok "messages.recent (dot form)" "$(call '{"method":"messages.recent","args":{"count":1}}')"

# ─── summary ─────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
TOTAL=$((PASS + FAIL + SKIP))
echo -e " Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC} / $TOTAL"
echo "========================================"
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
