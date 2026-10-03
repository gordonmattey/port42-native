#!/bin/bash
# The two-instance acceptance test (docs/plan-two-agents-one-port.md): two Port42 instances on this Mac, an
# agent on each side, working on one shared port. Real companions (claude) do the work; the script sets the
# scene, gives the instructions, and checks each step on both sides.
#
#   scripts/test-two-instances.sh <host port> <host token file> <guest port> <guest token file>
#   e.g. scripts/test-two-instances.sh 4248 ~/.port42/port42dev6/tokens/nautilus 4253 ~/.port42/port42dev11/tokens/nautilus
#
# The person clicks the cards it raises: Share (edit is asked every time) on the host, and the first time
# the guest's agent wakes the host's ("An Agent From Another Machine"). Steps print PASS or FAIL; the exit code
# is the number of failures. Agents are slow and not deterministic: each wait has a timeout, and a FAIL names
# what was missing.
set -u
HP=$1; HT=$2; GP=$3; GT=$4
A() { PORT42_GATEWAY_PORT=$HP PORT42_TOKEN_FILE=$HT port42 "$@"; }
B() { PORT42_GATEWAY_PORT=$GP PORT42_TOKEN_FILE=$GT port42 "$@"; }
J() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }
field() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
# chat_has <host|guest> <chat> <python predicate on entry e> <timeout s>
chat_has() {
  local side=$1 chat=$2 pred=$3 limit=$4 t=0
  while [ $t -lt "$limit" ]; do
    if { [ "$side" = host ] && A chat.read port="$chat" limit:=60 || B chat.read port="$chat" limit:=60; } 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); es=d if isinstance(d,list) else d.get('entries',[])
sys.exit(0 if any(($pred) for e in es) else 1)"; then return 0; fi
    sleep 10; t=$((t+10))
  done
  return 1
}

RUN=$(date +%H%M%S)
echo "== setup (run $RUN)"
SA=$(A space.create name="studio-$RUN" | field "d['id']"); SB=$(B space.create name="visit-$RUN" | field "d['id']")
[ -n "$SA" ] && [ -n "$SB" ] || { echo "cannot reach both instances"; exit 99; }
BOARD=$(A port.create type=web title="Shared board $RUN" space_id=$SA html='<title>Shared board</title><h1>Shared board</h1><ul id=c></ul>' | field "d['id']")
A companions.create name="alba$RUN" agent=claude space_id=$SA >/dev/null
B companions.create name="bram$RUN" agent=claude space_id=$SB >/dev/null
ALBA="alba$RUN"; BRAM="bram$RUN"
sleep 25   # the two CLIs start

echo "== 1. host shares (click Share on the host)"
# A card left unanswered past the call's timeout acts for nobody (#247): ask again, up to three times.
LINK=""
for try in 1 2 3; do
  echo "   waiting for the Share card on the host (try $try of 3)"
  LINK=$(A invite.create port=$BOARD rights:='["see","use","edit","wake_agents"]' 2>/dev/null | field "d['link']")
  [ -n "$LINK" ] && break
done
[ -n "$LINK" ] && pass "1 invite made with see, use, edit, wake_agents" || { fail "1 no invite"; exit $FAILS; }

echo "== 2. guest accepts, bringing $BRAM"
TILE=$(B invite.accept link="$LINK" remoteWake:=true companions:="[\"$BRAM\"]" | field "d['tile']")
[ -n "$TILE" ] && pass "2 tile opened on the guest" || { fail "2 no tile"; exit $FAILS; }

echo "== 3. $BRAM, brought in, says hello in the port's chat (it should reach the host)"
chat_has host $BOARD "e.get('fromName','').startswith('$BRAM (')" 240 && pass "3 $BRAM spoke in the shared chat" || fail "3 $BRAM did not speak in the shared chat"

echo "== 4. $BRAM talks to $ALBA (click 'An Agent From Another Machine' on the host)"
BR=$(B ports.list | field "[p['id'] for p in d if p['title']=='$BRAM'][0]")
B chat.post port=$BR text:="$(J "@$BRAM please ask @$ALBA, in the Shared board's chat, whether the board should get a Done list, and agree on it with them.")" >/dev/null
chat_has host $BOARD "e.get('fromName','')=='$ALBA'" 300 && pass "4 $ALBA answered in the shared chat" || fail "4 $ALBA never answered"

echo "== 5. $BRAM changes the code"
B chat.post port=$BR text:="$(J "@$BRAM please add a heading 'made on two machines $RUN' to the Shared board with one port.patch.")" >/dev/null
t=0; until A port.getHtml id=$BOARD | grep -q "made on two machines $RUN" || [ $t -ge 240 ]; do sleep 10; t=$((t+10)); done
A port.getHtml id=$BOARD | grep -q "made on two machines $RUN" && pass "5 the guest's change is on the host" || fail "5 the change never landed"
A port.history id=$BOARD | grep -q "$BRAM (" && pass "5 the version names $BRAM" || fail "5 the version does not name $BRAM"

echo "== 6. both edit at once"
AL=$(A ports.list | field "[p['id'] for p in d if p['title']=='$ALBA'][0]")
A chat.post port=$AL text:="$(J "@$ALBA please add the text 'alba-$RUN' at the end of the Shared board's body with one port.patch.")" >/dev/null &
B chat.post port=$BR text:="$(J "@$BRAM please add the text 'bram-$RUN' at the end of the Shared board's body with one port.patch.")" >/dev/null &
wait
t=0; until { H=$(A port.getHtml id=$BOARD); echo "$H" | grep -q "alba-$RUN" && echo "$H" | grep -q "bram-$RUN"; } || [ $t -ge 300 ]; do sleep 10; t=$((t+10)); done
H=$(A port.getHtml id=$BOARD); echo "$H" | grep -q "alba-$RUN" && echo "$H" | grep -q "bram-$RUN" && pass "6 both edits landed" || fail "6 an edit was lost"

echo "== 7. host takes edit away"
PEER=$(A invite.shared port=$BOARD | field "d[0]['peer']")
A invite.setRights port=$BOARD peer=$PEER rights:='["use","wake_agents"]' >/dev/null && pass "7 edit taken away" || fail "7 could not take edit away"
B chat.post port=$BR text:="$(J "@$BRAM please add the word 'beta-$RUN' to the Shared board heading with one port.patch, and tell me exactly what happened.")" >/dev/null
sleep 120
A port.getHtml id=$BOARD | grep -q "beta-$RUN" && fail "7 a patch landed without edit" || pass "7 no patch without edit"

echo "== 8. host stops sharing"
A invite.stop port=$BOARD peer=$PEER >/dev/null && pass "8 sharing stopped" || fail "8 could not stop sharing"
sleep 8
ERR=$(B port.getHtml id=$TILE 2>&1)
echo "$ERR" | grep -q "no longer shares\|not_granted\|not_found" && pass "8 the guest is told it is no longer shared" || fail "8 the guest got: $ERR"

echo "== $FAILS failing"
exit $FAILS
