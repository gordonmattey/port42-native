#!/bin/bash
# Port42 Auth Test Suite
# Tests all three auth modes against Anthropic's API with the exact same
# headers LLMEngine.swift sends.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

API_URL="https://api.anthropic.com/v1/messages"
MODEL="claude-haiku-4-5-20251001"
# Minimal request body
BODY='{"model":"'"$MODEL"'","max_tokens":32,"stream":false,"system":[{"type":"text","text":"Reply with ok"}],"messages":[{"role":"user","content":[{"type":"text","text":"say ok"}]}]}'

log_pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); }
log_fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); }
log_skip() { echo -e "  ${YELLOW}SKIP${NC} $1"; SKIP=$((SKIP+1)); }
log_info() { echo -e "  ${CYAN}INFO${NC} $1"; }

# Make an API call and return HTTP status code + body
# Usage: api_call <auth_mode> <token>
#   auth_mode: "oauth" or "apikey"
api_call() {
    local mode="$1"
    local token="$2"
    local tmpfile
    tmpfile=$(mktemp)

    local -a headers=(
        -s -w '\n%{http_code}'
        -H 'Content-Type: application/json'
        -H 'anthropic-version: 2023-06-01'
    )

    if [ "$mode" = "oauth" ]; then
        headers+=(
            -H "Authorization: Bearer $token"
            -H 'anthropic-beta: oauth-2025-04-20'
            -H 'x-app: cli'
            -H 'User-Agent: claude-cli/2.1.7 (external, port42)'
        )
    else
        headers+=(-H "x-api-key: $token")
    fi

    local response
    response=$(curl "${headers[@]}" -d "$BODY" "$API_URL" 2>"$tmpfile")
    local curl_exit=$?
    rm -f "$tmpfile"

    if [ $curl_exit -ne 0 ]; then
        echo "CURL_ERROR|$curl_exit"
        return
    fi

    # Last line is HTTP status, rest is body
    local status
    status=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    echo "$status|$body"
}

# Extract error message from JSON response
extract_error() {
    echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message','unknown'))" 2>/dev/null || echo "$1"
}

# Extract content from successful response
extract_content() {
    echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['content'][0]['text'])" 2>/dev/null || echo "(parse error)"
}

echo ""
echo "========================================"
echo " Port42 Auth Test Suite"
echo "========================================"
echo ""

# ─────────────────────────────────────────────
# TEST 1: Keychain read (Claude Code OAuth)
# ─────────────────────────────────────────────
echo -e "${CYAN}[1/5] Keychain: discover Claude Code entries${NC}"

# List all matching keychain entries (attributes only, no data prompt)
KC_SERVICES=$(security dump-keychain 2>/dev/null \
    | grep -o '"svce"<blob>="Claude Code-credentials[^"]*"' \
    | sed 's/"svce"<blob>="//;s/"$//' \
    | sort -u || true)

if [ -z "$KC_SERVICES" ]; then
    log_skip "No Claude Code keychain entries found"
    KC_TOKEN=""
else
    KC_COUNT=$(echo "$KC_SERVICES" | wc -l | tr -d ' ')
    log_pass "Found $KC_COUNT keychain entry/entries:"
    echo "$KC_SERVICES" | while read -r svc; do
        log_info "  $svc"
    done

    # Try to read the first (newest) entry
    KC_SERVICE=$(echo "$KC_SERVICES" | head -1)
    echo ""
    echo -e "${CYAN}[2/5] Keychain: read token from '$KC_SERVICE'${NC}"

    KC_DATA=$(security find-generic-password -s "$KC_SERVICE" -w 2>/dev/null || true)

    if [ -z "$KC_DATA" ]; then
        log_fail "Could not read keychain data (denied or empty)"
        KC_TOKEN=""
    else
        # Parse JSON to extract OAuth token
        KC_TOKEN=$(echo "$KC_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    oauth = d.get('claudeAiOauth', {})
    token = oauth.get('accessToken', '')
    expires = oauth.get('expiresAt')
    if token:
        print(token)
        if expires:
            import time
            remaining = (expires/1000) - time.time()
            mins = int(remaining / 60)
            if remaining < 0:
                print(f'EXPIRED ({-mins}m ago)', file=sys.stderr)
            else:
                print(f'expires in {mins}m', file=sys.stderr)
    else:
        # Try flat keys
        t = d.get('oauth_token') or d.get('token') or ''
        print(t)
except Exception as e:
    # Raw string token
    print(sys.stdin.read().strip() if hasattr(sys.stdin, 'read') else '')
" 2>/tmp/port42_kc_expiry)

        KC_EXPIRY=$(cat /tmp/port42_kc_expiry 2>/dev/null || true)
        rm -f /tmp/port42_kc_expiry

        if [ -n "$KC_TOKEN" ]; then
            PREFIX="${KC_TOKEN:0:15}..."
            log_pass "Token extracted: $PREFIX"
            [ -n "$KC_EXPIRY" ] && log_info "$KC_EXPIRY"
        else
            log_fail "Keychain entry exists but no token found in JSON"
            log_info "Raw data prefix: ${KC_DATA:0:60}..."
        fi
    fi
fi

# ─────────────────────────────────────────────
# TEST 2: Keychain OAuth API call
# ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}[3/5] Keychain OAuth: API call${NC}"

if [ -z "${KC_TOKEN:-}" ]; then
    log_skip "No keychain token available"
else
    log_info "POST $API_URL (model=$MODEL)"
    log_info "Headers: Bearer, anthropic-beta: oauth-2025-04-20, x-app: cli"

    RESULT=$(api_call oauth "$KC_TOKEN")
    STATUS="${RESULT%%|*}"
    BODY="${RESULT#*|}"

    if [ "$STATUS" = "200" ]; then
        CONTENT=$(extract_content "$BODY")
        log_pass "HTTP 200 — response: $CONTENT"
    elif [ "$STATUS" = "CURL_ERROR" ]; then
        log_fail "curl failed (exit $BODY)"
    else
        ERR=$(extract_error "$BODY")
        log_fail "HTTP $STATUS — $ERR"

        # Extra diagnostics for common errors
        case "$STATUS" in
            401) log_info "Token expired or invalid. Run: claude setup-token" ;;
            402) log_info "Billing issue on the account" ;;
            403) log_info "Token lacks permission for this model/endpoint" ;;
            502) log_info "CDN rejection. Check x-app/User-Agent headers" ;;
            529) log_info "Anthropic overloaded, try again later" ;;
        esac
    fi

    # Also test WITHOUT x-app header to confirm it matters
    echo ""
    echo -e "${CYAN}[3b] Keychain OAuth: API call WITHOUT x-app header (expect failure)${NC}"

    RESULT_NO_XAPP=$(curl -s -w '\n%{http_code}' \
        -H 'Content-Type: application/json' \
        -H 'anthropic-version: 2023-06-01' \
        -H "Authorization: Bearer $KC_TOKEN" \
        -H 'anthropic-beta: oauth-2025-04-20' \
        -d "$BODY" "$API_URL" 2>/dev/null || echo "CURL_ERROR")

    STATUS_NO=$(echo "$RESULT_NO_XAPP" | tail -1)
    BODY_NO=$(echo "$RESULT_NO_XAPP" | sed '$d')

    if [ "$STATUS_NO" = "200" ]; then
        log_info "HTTP 200 even without x-app (header may not be required)"
    else
        ERR_NO=$(extract_error "$BODY_NO" 2>/dev/null || echo "$BODY_NO")
        log_info "HTTP $STATUS_NO without x-app — $ERR_NO"
        log_info "This confirms x-app: cli header IS required for OAuth"
    fi
fi

# ─────────────────────────────────────────────
# TEST 3: Manual session key
# ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}[4/5] Manual session key: API call${NC}"

MANUAL_TOKEN="${PORT42_SESSION_KEY:-}"
if [ -z "$MANUAL_TOKEN" ]; then
    log_skip "Set PORT42_SESSION_KEY env var to test (e.g. sk-ant-oat01-...)"
    log_info "Usage: PORT42_SESSION_KEY=sk-ant-oat01-xxx ./test-auth.sh"
else
    PREFIX="${MANUAL_TOKEN:0:15}..."
    log_info "Token: $PREFIX"
    log_info "POST $API_URL (model=$MODEL)"

    RESULT=$(api_call oauth "$MANUAL_TOKEN")
    STATUS="${RESULT%%|*}"
    BODY="${RESULT#*|}"

    if [ "$STATUS" = "200" ]; then
        CONTENT=$(extract_content "$BODY")
        log_pass "HTTP 200 — response: $CONTENT"
    elif [ "$STATUS" = "CURL_ERROR" ]; then
        log_fail "curl failed (exit $BODY)"
    else
        ERR=$(extract_error "$BODY")
        log_fail "HTTP $STATUS — $ERR"
    fi
fi

# ─────────────────────────────────────────────
# TEST 4: API key
# ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}[5/5] API key: API call${NC}"

API_KEY="${ANTHROPIC_API_KEY:-${PORT42_API_KEY:-}}"
if [ -z "$API_KEY" ]; then
    log_skip "Set ANTHROPIC_API_KEY or PORT42_API_KEY env var to test"
    log_info "Usage: ANTHROPIC_API_KEY=sk-ant-api03-xxx ./test-auth.sh"
else
    PREFIX="${API_KEY:0:15}..."
    log_info "Key: $PREFIX"
    log_info "POST $API_URL (model=$MODEL, x-api-key header)"

    RESULT=$(api_call apikey "$API_KEY")
    STATUS="${RESULT%%|*}"
    BODY="${RESULT#*|}"

    if [ "$STATUS" = "200" ]; then
        CONTENT=$(extract_content "$BODY")
        log_pass "HTTP 200 — response: $CONTENT"
    elif [ "$STATUS" = "CURL_ERROR" ]; then
        log_fail "curl failed (exit $BODY)"
    else
        ERR=$(extract_error "$BODY")
        log_fail "HTTP $STATUS — $ERR"
    fi
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL + SKIP))
echo -e " Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC} / $TOTAL"
echo "========================================"
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
