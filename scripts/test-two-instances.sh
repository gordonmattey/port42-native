#!/bin/bash
# The two-instance acceptance test (docs/plan-two-agents-one-port.md): two Port42 instances on this Mac, an
# agent on each side, working together on one shared kanban board over several rounds. Real companions
# (claude) do the work; the script sets the scene, gives the instructions, and checks both sides.
#
#   scripts/test-two-instances.sh <host port> <host token file> <guest port> <guest token file> [rounds]
#   e.g. scripts/test-two-instances.sh 4248 ~/.port42/port42dev6/tokens/nautilus 4253 ~/.port42/port42dev11/tokens/nautilus 4
#
# The person clicks the cards it raises on the host: Share (edit is asked every time), and the first time the
# guest's agent wakes the host's ("An Agent From Another Machine"). Steps print PASS or FAIL; the exit code is
# the number of failures. Agents are slow and not deterministic: each wait has a timeout, and a FAIL names
# what was missing.
set -u
HP=$1; HT=$2; GP=$3; GT=$4; ROUNDS=${5:-3}
A() { PORT42_GATEWAY_PORT=$HP PORT42_TOKEN_FILE=$HT port42 "$@"; }
B() { PORT42_GATEWAY_PORT=$GP PORT42_TOKEN_FILE=$GT port42 "$@"; }
J() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }
field() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
# chat_has <host|guest> <chat> <python predicate on entry e; who(e) is its author> <timeout s>
chat_has() {
  local side=$1 chat=$2 pred=$3 limit=$4 t=0
  while [ $t -lt "$limit" ]; do
    if { [ "$side" = host ] && A chat.read port="$chat" limit:=80 || B chat.read port="$chat" limit:=80; } 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); es=d if isinstance(d,list) else d.get('entries',[])
who=lambda e: (e.get('from') or {}).get('name') or e.get('fromName') or ''   # chat.read nests the author under from
sys.exit(0 if any(($pred) for e in es) else 1)"; then return 0; fi
    sleep 10; t=$((t+10))
  done
  return 1
}
# wait_html <grep pattern> <timeout s>: the host's page code contains it
wait_html() { local t=0; until A port.getHtml id=$BOARD 2>/dev/null | grep -q "$1" || [ $t -ge "$2" ]; do sleep 10; t=$((t+10)); done; A port.getHtml id=$BOARD | grep -q "$1"; }
# who made the host's versions after version $1
authors_since() { A port.history id=$BOARD | python3 -c "import sys,json;d=json.load(sys.stdin);print(' '.join(sorted({str(v.get('createdBy')) for v in d if v['version']>$1})))" 2>/dev/null; }
last_version() { A port.history id=$BOARD | python3 -c "import sys,json;print(max(v['version'] for v in json.load(sys.stdin)))" 2>/dev/null; }
token_of() { A ports.list | field "[p['token'] for p in d if p['id']=='$1'][0]"; }

RUN=$(date +%H%M%S)
ALBA="alba$RUN"; BRAM="bram$RUN"
echo "== setup (run $RUN, $ROUNDS rounds)"
SA=$(A space.create name="studio-$RUN" | field "d['id']"); SB=$(B space.create name="visit-$RUN" | field "d['id']")
[ -n "$SA" ] && [ -n "$SB" ] || { echo "cannot reach both instances"; exit 99; }
BOARD_HTML=$(mktemp -t board).html
cat > "$BOARD_HTML" <<'HTML'
<title>Team board</title>
<style>
body{background:#0f1720;color:#e6edf3;font:13px ui-monospace,monospace;margin:0;padding:14px}
h1{font-size:15px;margin:0 0 10px}.cols{display:flex;gap:10px}
.col{flex:1;background:#16212c;border-radius:8px;padding:8px;min-height:140px}
.col h2{font-size:12px;margin:0 0 6px;opacity:.8}
.card{background:#203040;border-radius:6px;padding:5px 7px;margin:5px 0;display:flex;gap:4px;align-items:center}
.card span{flex:1}button{background:#2b4a63;color:#fff;border:0;border-radius:4px;padding:2px 6px;cursor:pointer}
input{background:#0b1218;color:#fff;border:1px solid #2b4a63;border-radius:4px;padding:3px;width:90%}
</style>
<h1>Team board</h1>
<div class="cols" id="cols"></div>
<script>
const COLS = ["To do", "Doing", "Done"];
let cards = [];
async function load() {
  try { const r = await port42.storage.get("cards"); const v = Array.isArray(r) ? r : (r && r.value); cards = Array.isArray(v) ? v : []; }
  catch (e) { cards = []; }
  render();
}
async function save() { try { await port42.storage.set("cards", cards); } catch (e) { console.error("save failed", e); } render(); }
function move(card, by) { card.col = Math.max(0, Math.min(COLS.length - 1, card.col + by)); save(); }
function render() {
  const root = document.getElementById("cols"); root.innerHTML = "";
  COLS.forEach((name, ci) => {
    const col = document.createElement("div"); col.className = "col"; col.dataset.col = ci;
    const h = document.createElement("h2"); h.textContent = name; col.appendChild(h);
    cards.filter(c => c.col === ci).forEach(c => {
      const d = document.createElement("div"); d.className = "card";
      const t = document.createElement("span"); t.textContent = c.text; d.appendChild(t);
      if (ci > 0) { const b = document.createElement("button"); b.textContent = "←"; b.onclick = () => move(c, -1); d.appendChild(b); }
      if (ci < COLS.length - 1) { const b = document.createElement("button"); b.textContent = "→"; b.onclick = () => move(c, 1); d.appendChild(b); }
      const x = document.createElement("button"); x.textContent = "x"; x.onclick = () => { cards = cards.filter(k => k !== c); save(); }; d.appendChild(x);
      col.appendChild(d);
    });
    const i = document.createElement("input"); i.placeholder = "add a card";
    i.onkeydown = e => { if (e.key === "Enter" && i.value.trim()) { cards.push({ text: i.value.trim(), col: ci }); save(); } };
    col.appendChild(i); root.appendChild(col);
  });
}
window.addCard = (text, col) => { cards.push({ text, col: col || 0 }); return save(); };
load();
</script>
HTML
BOARD=$(A port.create type=web title="Team board $RUN" space_id=$SA html=@"$BOARD_HTML" | field "d['id']")
A companions.create name="$ALBA" agent=claude space_id=$SA >/dev/null
B companions.create name="$BRAM" agent=claude space_id=$SB >/dev/null
sleep 25   # the two CLIs start

echo "== 1. host shares (click Share on the host)"
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

echo "== 3. $BRAM, brought in, says hello in the port's chat"
chat_has host $BOARD "who(e).startswith('$BRAM')" 240 && pass "3 $BRAM spoke in the shared chat" || fail "3 $BRAM did not speak in the shared chat"

BR=$(B ports.list | field "[p['id'] for p in d if p['title']=='$BRAM'][0]")
AL=$(A ports.list | field "[p['id'] for p in d if p['title']=='$ALBA'][0]")

echo "== 4. $BRAM and $ALBA meet (click 'An Agent From Another Machine' on the host)"
B chat.post port=$BR text:="$(J "@$BRAM please say hello to @$ALBA in the Team board's chat and agree how you two will work on the board together: who reviews whose changes, and how you avoid overwriting each other.")" >/dev/null
chat_has host $BOARD "who(e)=='$ALBA'" 300 && pass "4 $ALBA answered in the shared chat" || fail "4 $ALBA never answered"

FEATURES=(
  "a count of the cards in each column, shown in that column's heading"
  "a filter box above the columns that hides cards whose text does not contain what is typed"
  "an owner on each card: a short name typed with the card, shown on it as a tag"
  "a 'Clear Done' button that removes every card in Done, after a confirm"
  "a colour per column: each column gets its own subtle background tint"
)
SEEN_AUTHORS=""
for ((r=1; r<=ROUNDS; r++)); do
  F="${FEATURES[$(( (r-1) % ${#FEATURES[@]} ))]}"
  TAG="f$r-$RUN"
  if (( r % 2 )); then LEAD=$BRAM; LEADCHAT=$BR; SIDE=B; OTHER=$ALBA; else LEAD=$ALBA; LEADCHAT=$AL; SIDE=A; OTHER=$BRAM; fi
  echo "== round $r: $LEAD leads, $OTHER helps: $F"
  V0=$(last_version)
  MSG="@$LEAD round $r. With @$OTHER, in the Team board's chat, add $F. Agree the plan there first, split the work so each of you makes at least one change to the board's code with port.patch, and give the new element the id '$TAG'. Keep what is already on the board working. When both changes are in, check the board's console has no errors, then say 'round $r done' in the board's chat."
  $SIDE chat.post port=$LEADCHAT text:="$(J "$MSG")" >/dev/null
  wait_html "$TAG" 600 && pass "round $r: the new element ($TAG) is on the host" || fail "round $r: no element $TAG"
  chat_has host $BOARD "'round $r done' in e.get('text','').lower()" 300 && pass "round $r: done was said in the shared chat" || fail "round $r: nobody said it was done"
  AUTH=$(authors_since "$V0")
  echo "   versions this round by: $AUTH"
  echo "$AUTH" | grep -q "$BRAM" && echo "$AUTH" | grep -q "$ALBA" && pass "round $r: both agents changed the code" || fail "round $r: not both agents changed the code ($AUTH)"
  ERR=$(A port.console id=$BOARD level=count | field "d['errors']")
  [ "${ERR:-1}" = "0" ] && pass "round $r: no console errors on the host" || fail "round $r: $ERR console errors on the host"
  A port.getHtml id=$BOARD | grep -q 'id="cols"' && pass "round $r: the board still renders its columns" || fail "round $r: the board lost its columns"
  SEEN_AUTHORS="$SEEN_AUTHORS $AUTH"
done

echo "== history names both agents"
echo "$SEEN_AUTHORS" | grep -q "$BRAM (" && echo "$SEEN_AUTHORS" | grep -q "$ALBA" && pass "history names $BRAM (from there) and $ALBA" || fail "history authors: $SEEN_AUTHORS"

echo "== the board's data: a card added through the page survives a reload on both sides"
A port.exec id=$BOARD token="$(token_of $BOARD)" js='return window.addCard ? window.addCard("card-'"$RUN"'", 0).then(()=>"ok") : "no addCard"' >/dev/null 2>&1
sleep 5
A port.manage id=$BOARD action=reload token="$(token_of $BOARD)" >/dev/null 2>&1
sleep 6
A port.getDom id=$BOARD | grep -q "card-$RUN" && pass "the card survived a reload on the host" || fail "the card was lost on reload (or the agents removed addCard)"
t=0; until B port.getDom id=$TILE 2>/dev/null | grep -q "card-$RUN" || [ $t -ge 60 ]; do sleep 5; t=$((t+5)); done
B port.getDom id=$TILE | grep -q "card-$RUN" && pass "the card shows on the guest's tile" || fail "the guest's tile does not show the card"

echo "== host takes edit away"
PEER=$(A invite.shared port=$BOARD | field "d[0]['peer']")
A invite.setRights port=$BOARD peer=$PEER rights:='["use","wake_agents"]' >/dev/null && pass "edit taken away" || fail "could not take edit away"
B chat.post port=$BR text:="$(J "@$BRAM please add the word 'beta-$RUN' to the Team board heading with one port.patch, and tell me exactly what happened.")" >/dev/null
sleep 120
A port.getHtml id=$BOARD | grep -q "beta-$RUN" && fail "a patch landed without edit" || pass "no patch without edit"

echo "== host stops sharing"
A invite.stop port=$BOARD peer=$PEER >/dev/null && pass "sharing stopped" || fail "could not stop sharing"
sleep 8
SHARED=$(B ports.list | field "[p['mirrors'].get('shared') for p in d if p['id']=='$TILE'][0]")
[ "$SHARED" = "False" ] && pass "the guest's tile shows it is no longer shared" || fail "the guest's tile still shows shared ($SHARED)"
ERR=$(B port.getHtml id=$TILE 2>&1)
echo "$ERR" | grep -q "no longer shares\|not_granted\|not_found" && pass "the guest is told it is no longer shared" || fail "the guest got: $ERR"

echo "== $FAILS failing"
exit $FAILS
