#!/bin/bash
# Say it, See it — automated port generation tests
#
# Tests that companions build ports (not just text) in response to various prompts.
# Requires Port42 running with at least one companion in a test channel.
#
# Usage:
#   ./test-sayitseeit.sh                    # run all tests
#   ./test-sayitseeit.sh --channel NAME     # target a specific channel (required)
#   ./test-sayitseeit.sh --companion NAME   # @mention a specific companion
#   ./test-sayitseeit.sh --wait SECONDS     # wait time for companion response (default 60)

HOST="http://127.0.0.1:4242"
PASS=0
FAIL=0
COMPANION="forge"
CHANNEL_NAME=""
CHANNEL_ID=""
WAIT=60
RESULTS=()

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --channel) CHANNEL_NAME="$2"; shift 2 ;;
    --companion) COMPANION="$2"; shift 2 ;;
    --wait) WAIT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

call() {
  curl -s --max-time 10 "$HOST/call" -d "$1"
}

# Get all port IDs as a newline-separated list
get_port_ids() {
  call '{"method":"ports.list"}' | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    content = d.get('content', '')
    ids = re.findall(r'id: ([A-F0-9-]+)', content)
    # deduplicate preserving order
    seen = set()
    for i in ids:
        if i not in seen:
            seen.add(i)
            print(i)
except:
    pass
" 2>/dev/null
}

# Get title for a port ID from ports.list output
get_port_title() {
  local port_id="$1"
  call '{"method":"ports.list"}' | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
content = d.get('content', '')
blocks = re.split(r'\n\n', content)
for block in blocks:
    if '$port_id' in block:
        m = re.search(r'title: (.+)', block)
        if m:
            print(m.group(1))
            break
" 2>/dev/null
}

# Send a message and wait for companion to respond
send_and_wait() {
  local prompt="$1"
  local msg="@${COMPANION} ${prompt}"

  # Use heredoc to avoid quote escaping issues
  local json_payload
  json_payload=$(python3 <<PYEOF
import json
msg = """${msg}"""
args = {"text": msg}
channel_id = """${CHANNEL_ID}"""
if channel_id:
    args["channel_id"] = channel_id
print(json.dumps({"method": "messages.send", "args": args}))
PYEOF
)

  curl -s --max-time 10 "$HOST/call" -d "$json_payload" > /dev/null 2>&1

  # Wait for companion to finish
  sleep "$WAIT"
}

# Run a single Say it See it test
run_test() {
  local name="$1"
  local prompt="$2"
  local expect="$3"

  echo ""
  echo "  [$name]"
  echo "    prompt: \"$prompt\""

  # Snapshot port IDs before
  local before
  before=$(get_port_ids)

  send_and_wait "$prompt"

  # Snapshot port IDs after
  local after
  after=$(get_port_ids)

  # Find new port IDs (in after but not in before)
  local new_ids
  new_ids=$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort))

  local built="no"
  if [ -n "$new_ids" ]; then
    built="yes"
    local first_new
    first_new=$(echo "$new_ids" | head -1)
    local title
    title=$(get_port_title "$first_new")
    local count
    count=$(echo "$new_ids" | wc -l | tr -d ' ')
    echo "    result: PORT built — \"$title\" ($count new port(s))"
  else
    echo "    result: TEXT only (no new ports)"
  fi

  case "$expect" in
    port)
      if [ "$built" = "yes" ]; then
        echo "    verdict: PASS"
        PASS=$((PASS+1))
        RESULTS+=("✓ $name")
      else
        echo "    verdict: FAIL — expected port, got text"
        FAIL=$((FAIL+1))
        RESULTS+=("✗ $name — expected port, got text")
      fi
      ;;
    text)
      if [ "$built" = "no" ]; then
        echo "    verdict: PASS"
        PASS=$((PASS+1))
        RESULTS+=("✓ $name")
      else
        echo "    verdict: FAIL — expected text, got port"
        FAIL=$((FAIL+1))
        RESULTS+=("✗ $name — expected text, got port")
      fi
      ;;
    either)
      echo "    verdict: OK (no preference)"
      PASS=$((PASS+1))
      RESULTS+=("~ $name — $built")
      ;;
  esac
}

# ── Preflight ────────────────────────────────────────────────────────

echo ""
echo "Say it, See it — Port Generation Tests"
echo "======================================="
echo "  companion: @$COMPANION"
echo "  wait time: ${WAIT}s per test"

# Check Port42 is running
R=$(curl -s --max-time 3 "$HOST/health" 2>/dev/null)
if ! echo "$R" | grep -q "ok"; then
  echo ""
  echo "  ✗ Port42 not running at $HOST"
  exit 1
fi
echo "  port42: running"

# Check companion exists
R=$(call '{"method":"companions.list"}')
if ! echo "$R" | grep -qi "$COMPANION"; then
  echo ""
  echo "  ✗ Companion '$COMPANION' not found"
  exit 1
fi
echo "  companion: found"

# Resolve channel ID
if [ -n "$CHANNEL_NAME" ]; then
  CHANNEL_ID=$(call '{"method":"channel.list"}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
content = d.get('content', '')
# Try JSON parse first
try:
    channels = json.loads(content)
    for ch in channels:
        if ch.get('name','').lower() == '${CHANNEL_NAME}'.lower():
            print(ch['id'])
            break
except:
    # Text format fallback
    import re
    blocks = content.split('\n\n')
    for block in blocks:
        if '${CHANNEL_NAME}' in block.lower():
            m = re.search(r'id: ([A-F0-9-]+)', block)
            if m:
                print(m.group(1))
                break
" 2>/dev/null)
  if [ -z "$CHANNEL_ID" ]; then
    echo "  ✗ Channel '$CHANNEL_NAME' not found"
    exit 1
  fi
  echo "  channel: $CHANNEL_NAME ($CHANNEL_ID)"
else
  echo "  channel: current (use --channel NAME to target specific channel)"
fi

# Count existing ports
EXISTING=$(get_port_ids | wc -l | tr -d ' ')
echo "  existing ports: $EXISTING"
echo ""

# ── Tests ────────────────────────────────────────────────────────────

echo "[ Tier 1: Imperative build — must always produce a port ]"

# pomodoro — already tested, skip
# run_test "pomodoro" \
#   "make me a pomodoro timer" \
#   "port"

run_test "binary-search" \
  "show me how a binary search works" \
  "port"

run_test "calorie-tracker" \
  "track my calories today" \
  "port"

run_test "spanish-quiz" \
  "quiz me on Spanish verb conjugations" \
  "port"

run_test "terminal" \
  "open me a terminal" \
  "port"

echo ""
echo "[ Tier 2: Scaffold-first — should build with empty fields, not ask in chat ]"

run_test "job-comparison" \
  "I need to decide between three job offers" \
  "port"

run_test "deal-evaluation" \
  "help me evaluate a business deal" \
  "port"

run_test "world-clocks" \
  "what time is it in Tokyo, London, and New York" \
  "port"

echo ""
echo "[ Tier 3: Vague complaints — should infer intent and build ]"

run_test "water-reminder" \
  "I keep forgetting to drink water throughout the day" \
  "port"

run_test "task-overwhelm" \
  "I have so many things to do and I do not know where to start" \
  "port"

run_test "meeting-prep" \
  "I have a big meeting tomorrow and I am not ready" \
  "port"

echo ""
echo "[ Tier 4: Questions that deserve live surfaces ]"

run_test "bill-splitter" \
  "how should I split this dinner bill between 4 people" \
  "port"

run_test "color-picker" \
  "I need a good color palette for my app" \
  "port"

run_test "password-gen" \
  "I need a strong password" \
  "port"

echo ""
echo "[ Tier 5: Anti-drowning pattern identification ]"

run_test "drowning-devtools" \
  "my deploys keep failing and I cannot figure out the CI logs" \
  "port"

run_test "drowning-data" \
  "I have a CSV with 10000 rows and I need to find the outliers" \
  "port"

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "======================================="
echo "  RESULTS"
echo "---------------------------------------"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done
echo "---------------------------------------"
echo "  passed: $PASS  failed: $FAIL"
echo ""
echo "  port generation rate: $PASS / $((PASS + FAIL)) ($(( PASS * 100 / (PASS + FAIL) ))%)"
echo ""

# Write results to file
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT="test-sayitseeit-results-${TIMESTAMP}.txt"
{
  echo "Say it, See it Test Results — $(date)"
  echo "Companion: @$COMPANION | Wait: ${WAIT}s"
  echo ""
  for r in "${RESULTS[@]}"; do
    echo "  $r"
  done
  echo ""
  echo "passed: $PASS  failed: $FAIL"
  echo "port generation rate: $PASS / $((PASS + FAIL))"
} > "$REPORT"
echo "  report saved: $REPORT"
echo ""

[ $FAIL -eq 0 ] && exit 0 || exit 1
