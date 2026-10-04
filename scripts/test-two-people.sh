#!/bin/bash
# The realistic two-instance scenario (docs/plan-two-agents-one-port.md): two people, each with their own agent,
# sharing one board and asking for things in plain words in its shared chat. Nothing is scripted for the agents:
# no rounds, ids, tools or "say done". The script plays both people, waits for the agents to go quiet after each
# request, and saves the transcript, the board's history and its final page for a person to judge.
#
#   scripts/test-two-people.sh <host port> <host token file> <guest port> <guest token file>
#
# The person clicks the cards on the host: Share, and "An Agent From Another Machine".
set -u
HP=$1; HT=$2; GP=$3; GT=$4
A() { PORT42_GATEWAY_PORT=$HP PORT42_TOKEN_FILE=$HT port42 "$@"; }
B() { PORT42_GATEWAY_PORT=$GP PORT42_TOKEN_FILE=$GT port42 "$@"; }
J() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }
field() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
count() { A chat.read port=$BOARD limit:=300 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d if isinstance(d,list) else d.get('entries',[])))" 2>/dev/null || echo 0; }
# quiet <idle s> <max s>: wait until the shared chat has had no new message for <idle> seconds
quiet() {
  local idle=$1 max=$2 t=0 last n same=0
  last=$(count)
  while [ $t -lt "$max" ]; do
    sleep 15; t=$((t+15)); n=$(count)
    if [ "$n" = "$last" ]; then same=$((same+15)); [ $same -ge "$idle" ] && return 0; else same=0; last=$n; fi
  done
  return 1
}
say_host()  { echo "   Gordon: $1"; A chat.post port=$BOARD text:="$(J "$1")" >/dev/null; }
say_guest() { echo "   Sam:    $1"; B chat.post port=$TILE  text:="$(J "$1")" >/dev/null; }

RUN=$(date +%H%M%S)
OUT=/private/tmp/claude-501/two-people-$RUN; mkdir -p $OUT
ALBA="alba$RUN"; BRAM="bram$RUN"
echo "== setup (run $RUN), output in $OUT"
SA=$(A space.create name="launch-$RUN" | field "d['id']"); SB=$(B space.create name="with-gordon-$RUN" | field "d['id']")
A space.switchTo space_id=$SA >/dev/null; B space.switchTo space_id=$SB >/dev/null
BOARD=$(A port.create type=web title="Board" space_id=$SA html='<title>Board</title><h1>Board</h1><p>Nothing here yet.</p>' | field "d['id']")
A companions.create name="$ALBA" agent=claude space_id=$SA >/dev/null
B companions.create name="$BRAM" agent=claude space_id=$SB >/dev/null
sleep 25

echo "== Gordon shares the board (click Share on the host)"
LINK=""
for try in 1 2 3; do LINK=$(A invite.create port=$BOARD rights:='["see","use","edit","wake_agents"]' 2>/dev/null | field "d['link']"); [ -n "$LINK" ] && break; done
[ -n "$LINK" ] || { echo "no invite"; exit 1; }
echo "== Sam opens it and brings $BRAM"
TILE=""
for try in 1 2 3; do TILE=$(B invite.accept link="$LINK" remoteWake:=true companions:="[\"$BRAM\"]" 2>/dev/null | field "d['tile']"); [ -n "$TILE" ] && break; sleep 15; done
[ -n "$TILE" ] || { echo "no tile"; exit 1; }
quiet 60 240

echo "== kickoff (click 'An Agent From Another Machine' on the host when it shows)"
say_host "@$ALBA, Sam's agent $BRAM is joining us on this board. Let's turn it into a planner for our launch: things to do, who is on them, and what's done."
say_guest "@$BRAM, help Gordon's team with their board."
quiet 120 900

for REQ in \
  "host|Can you two make it so we can add cards and move them along as work gets done?" \
  "guest|Could each card show who owns it?" \
  "host|Done is going to get long. Add a way to clear it out, but ask first." \
  "guest|It would help to see at a glance how many cards are in each column." \
  "host|Make it so a card I add on my side shows up for Sam straight away, and the other way round."; do
  WHO=${REQ%%|*}; TEXT=${REQ#*|}
  echo "== request"
  if [ "$WHO" = host ]; then say_host "@$ALBA @$BRAM $TEXT"; else say_guest "@$BRAM $TEXT"; fi
  quiet 120 900 || echo "   (still talking after 15 minutes; moving on)"
done

echo "== saving what happened"
A chat.read port=$BOARD limit:=400 > $OUT/chat.json
A port.history id=$BOARD > $OUT/history.json
A port.getHtml id=$BOARD > $OUT/board.html
A port.getDom id=$BOARD > $OUT/host-dom.json
B port.getDom id=$TILE > $OUT/guest-dom.json 2>&1
A port.console id=$BOARD > $OUT/console.json
python3 - "$OUT" "$ALBA" "$BRAM" <<'PY'
import json,sys,collections
out,alba,bram=sys.argv[1:4]
d=json.load(open(out+'/chat.json')); es=d if isinstance(d,list) else d.get('entries',[])
who=lambda e:(e.get('from') or {}).get('name') or '?'
c=collections.Counter(who(e) for e in es)
h=json.load(open(out+'/history.json'))
v=collections.Counter(str(x.get('createdBy')) for x in h)
con=json.load(open(out+'/console.json'))
print('messages by author:', dict(c))
print('versions by author:', dict(v))
print('console:', {k:con.get(k) for k in ('errors','warnings')})
PY
echo "== done: $OUT"
