#!/bin/bash
# Port42 HTTP API test suite

HOST="http://127.0.0.1:4242"
PASS=0
FAIL=0

call() {
  curl -s "$HOST/call" -d "$1"
}

check() {
  local name="$1"
  local result="$2"
  local expect="$3"
  if echo "$result" | grep -q "$expect"; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name"
    echo "    got: $(echo $result | head -c 120)"
    FAIL=$((FAIL+1))
  fi
}

echo ""
echo "Port42 HTTP API Tests"
echo "====================="

# Health
echo ""
echo "[ health ]"
R=$(curl -s "$HOST/health")
check "GET /health" "$R" "ok"

# User
echo ""
echo "[ user ]"
R=$(call '{"method":"user.get"}')
check "user.get returns name" "$R" "displayName"
check "user.get returns id"   "$R" "id"

# Channels
echo ""
echo "[ channels ]"
R=$(call '{"method":"channel.list"}')
check "channel.list returns array" "$R" "\["
CHANNEL_ID=$(echo "$R" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['content'] if isinstance(json.loads(d['content']), str) else json.loads(d['content'])[0]['id'])" 2>/dev/null || echo "")
if [ -z "$CHANNEL_ID" ]; then
  CHANNEL_ID=$(echo "$R" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
check "channel.list has id" "$CHANNEL_ID" "."

# Companions
echo ""
echo "[ companions ]"
R=$(call '{"method":"companions.list"}')
check "companions.list returns array" "$R" "\["
check "companions.list has name" "$R" "echo"

# Clipboard
echo ""
echo "[ clipboard ]"
R=$(call '{"method":"clipboard.write","args":{"text":"port42-test-value"}}')
check "clipboard.write ok" "$R" "ok"
R=$(call '{"method":"clipboard.read"}')
check "clipboard.read returns data" "$R" "port42-test-value"

# Messages
echo ""
echo "[ messages ]"
if [ -n "$CHANNEL_ID" ]; then
  R=$(call "{\"method\":\"messages.recent\",\"args\":{\"count\":3,\"channel_id\":\"$CHANNEL_ID\"}}")
  check "messages.recent returns array" "$R" "\["
  R=$(call "{\"method\":\"messages.send\",\"args\":{\"text\":\"[test-http.sh] api test $(date +%H:%M:%S)\",\"channel_id\":\"$CHANNEL_ID\"}}")
  check "messages.send ok" "$R" "ok"
else
  echo "  - skipped (no channel id)"
fi

# Terminal
echo ""
echo "[ terminal ]"
R=$(call '{"method":"terminal.exec","args":{"command":"echo port42-terminal-ok"}}')
check "terminal.exec stdout" "$R" "port42-terminal-ok"
R=$(call '{"method":"terminal.exec","args":{"command":"whoami"}}')
check "terminal.exec whoami" "$R" "gordon"

# Screen
echo ""
echo "[ screen ]"
R=$(call '{"method":"screen_capture","args":{"scale":0.1}}')
check "screen_capture returns image" "$R" "image"

# Summary
echo ""
echo "====================="
echo "  passed: $PASS  failed: $FAIL"
echo ""
[ $FAIL -eq 0 ] && exit 0 || exit 1
