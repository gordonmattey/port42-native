#!/usr/bin/env python3
"""The five nautilus scenarios (docs/plan-shell-only.md), run live against a Port42 dev instance.

    P42_TOKEN_FILE=~/.port42/port42dev3/tokens/nautilus-harness \
        scripts/scenarios/run.py --port 4245 [--only 2,3] [--agent swift-otter] [--no-restart] [--keep]

Prints one row per scenario with its evidence and exits non-zero if any scenario fails.

- Scenario 1 opens a fresh terminal running --cli (default claude), waits for it to register as a
  companion, and asks it for a port. It costs one agent turn and needs the `terminal` grant on port 0.
  --agent asks an existing companion instead, which measures its transcript as much as Port42.
- Scenario 5 restarts the instance it is pointed at, unless --no-restart.
- Every port the harness makes is titled "harness:" and closed at the end, unless --keep.
"""
import argparse, asyncio, json, os, re, signal, subprocess, sys, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from p42 import Client, Refused, WSGuest  # noqa: E402

RESULTS = []
MADE = []
TITLES = {}


def record(n, name, ok, evidence):
    RESULTS.append((n, name, "PASS" if ok else ("SKIP" if ok is None else "FAIL"), evidence))


def made(port):
    MADE.append(port["id"])
    TITLES[port["id"]] = port.get("title")
    return port


def page(body, script=""):
    return (f"<body style='background:#111;color:#0fa;font:14px monospace'>{body}"
            f"<script>{script}</script></body>")


def dom_text(c, pid, element="log"):
    html = c.call("port.getDom", {"id": pid}).get("html", "")
    m = re.search(rf'<pre id="?{element}"?>(.*?)</pre>', html, re.S)
    return m.group(1).strip() if m else ""


# ---------------------------------------------------------------------------------------------- 1
def fresh_agent(c, cli):
    """Open a terminal running `cli` and wait for it to register as a companion.

    A FRESH session, on purpose: a resumed companion answers from its old transcript and never reads
    the current manual (2026-09-25, audit F14), so it measures its memory rather than Port42.
    Needs the `terminal` grant on port 0 for the harness client.
    """
    title = f"harness: s1 {cli}"
    t = made(c.call("port.create", {"type": "terminal", "title": title, "command": cli}, timeout=120))
    # Not read back from the member list: it lags and duplicates (audit F15). Mention routing finds the
    # companion by name once it auto-registers, which the terminal's sessionStarted hook does within
    # seconds; the wait covers that and the CLI's own boot.
    time.sleep(12)
    return "harness-s1-" + cli


def scenario1(c, agent, cli):
    """Asked in the space's chat (every port has one; a space is a port). Passes when the port appears,
    the harness's own post is attributed to the harness, and the companion's reply lands back in the
    same chat attributed to the companion (docs/design-chat-port.md, build step 3)."""
    nonce = "harness s1 " + uuid.uuid4().hex[:6]
    agent = agent or fresh_agent(c, cli)
    space = c.call("space.current")["id"]
    posted = c.call("chat.post", {"port": space,
                                  "text": f"@{agent} make a web port titled '{nonce}' that shows the current time, ticking."})
    mine = posted["entry"]
    if mine["from"]["kind"] != "peer":
        return record(1, "Make a thing", False, f"the harness's post was attributed to {mine['from']!r}")
    t0, port, reply = time.time(), None, None
    while time.time() - t0 < 240 and not (port and reply):
        if not port:
            hit = [p for p in c.call("ports.list") if p.get("title") == nonce]
            if hit:
                port = hit[0]
                MADE.append(port["id"])
        if not reply:
            later = c.call("chat.read", {"port": space, "after": mine["seq"]})["entries"]
            reply = next((e for e in later if e["from"]["name"].lower() == agent.lower()), None)
        time.sleep(3)
    if not port:
        return record(1, "Make a thing", False, f"@{agent}: no port titled '{nonce}' within 240s")
    if not reply:
        return record(1, "Make a thing", False, f"@{agent}: the port appeared but no reply came back to the chat")
    if reply["from"]["kind"] != "companion":
        return record(1, "Make a thing", False, f"@{agent}'s reply was attributed to {reply['from']!r}")
    record(1, "Make a thing", True,
           f"@{agent}: '{nonce}' appeared and the reply landed in the space chat after {time.time() - t0:.0f}s")


# ---------------------------------------------------------------------------------------------- 2
def scenario2(c):
    me = c.call("port.info")
    p = made(c.call("port.create", {"type": "web", "title": "harness: s2 drive", "html": page("<h1>v0</h1>")}))
    tokens = [p["token"]]
    for v in (1, 2, 3):
        r = c.call("port.update", {"id": p["id"], "token": tokens[-1], "html": page(f"<h1>v{v}</h1>")})
        tokens.append(r["token"])
    moved = len(set(tokens)) == 4
    try:
        c.call("port.update", {"id": p["id"], "token": tokens[0], "html": page("stale")})
        stale = "stale write LANDED"
    except Refused as e:
        stale = e.code if e.body.get("current") == tokens[-1] else f"{e.code} without the right current"
    try:
        c.call("port.update", {"id": p["id"], "html": page("no token")})
        notoken = "tokenless write LANDED"
    except Refused as e:
        notoken = e.code
    by = next(x for x in c.call("ports.list") if x["id"] == p["id"]).get("createdBy")
    ok = moved and stale == "stale_write" and notoken == "token_required" and by == me.get("id")
    record(2, "Drive a thing", ok,
           f"tokens {' → '.join(tokens)}; stale: {stale}; no token: {notoken}; createdBy {by!r} (caller {me.get('id')!r})")


# ---------------------------------------------------------------------------------------------- 3
def scenario3(c):
    a = made(c.call("port.create", {"type": "web", "title": "harness: s3 produce", "html": page(
        "<h1>produce</h1>",
        "var n=0; setInterval(function(){ n++; port42.port.publish('state',{n:n, at:Date.now()}); }, 500);")}))
    t = made(c.call("port.create", {"type": "web", "title": "harness: s3 transform", "html": page(
        "<h1>transform</h1>",
        "port42.port.subscribe('%s', function(ev){ if(ev.kind.indexOf('state')<0) return;"
        " port42.port.publish('state',{v:ev.payload.n*10, at:ev.payload.at}); });" % a["id"])}))
    r = made(c.call("port.create", {"type": "web", "title": "harness: s3 render", "html": page(
        "<h1>render</h1><pre id=log></pre>",
        "port42.port.subscribe('%s', function(ev){ if(ev.kind.indexOf('state')<0) return;"
        " document.getElementById('log').textContent += ev.payload.v+' '+(Date.now()-ev.payload.at)+'ms\\n'; });"
        % t["id"])}))
    time.sleep(6)
    rows = [ln.split() for ln in dom_text(c, r["id"]).splitlines() if ln.strip()]
    values = [int(x[0]) for x in rows]
    lags = [int(x[1][:-2]) for x in rows]
    ok = len(values) >= 5 and all(v % 10 == 0 for v in values) and values == sorted(values)
    lag = f"median {sorted(lags)[len(lags) // 2]}ms, max {max(lags)}ms" if lags else "none"
    record(3, "Compose things", ok,
           f"render received {len(values)} transformed events in 6s ({values[:3]}…), produce→render {lag}")


# ---------------------------------------------------------------------------------------------- 4
async def _scenario4(c):
    import urllib.request
    p = made(c.call("port.create", {"type": "web", "title": "harness: s4 share", "html": page("<h1>here</h1>")}))
    served = urllib.request.urlopen(f"{c.base}/port?id={p['id']}", timeout=5).status
    async with WSGuest(c) as g:
        sub = await g.subscribe(p["id"])
        await asyncio.sleep(0.5)
        refused_sub = sub.result() if sub.done() else None
        # a write HERE must reach the guest THERE as a live event
        here = c.call("port.update", {"id": p["id"], "token": p["token"], "html": page("<h1>written here</h1>")})
        await asyncio.sleep(1)
        live = [f for f in g.frames if isinstance(f, dict) and f.get("kind") == "state"]
        stale = await g.call("port.update", {"id": p["id"], "token": p["token"], "html": page("guest stale")})
        retry = await g.call("port.update", {"id": p["id"], "token": (stale or {}).get("current", ""),
                                             "html": page("<h1>written by the guest</h1>")})
    landed = "written by the guest" in (c.call("port.getHtml", {"id": p["id"]}) or "")
    ok = (served == 200 and refused_sub is None and live and (stale or {}).get("code") == "stale_write"
          and isinstance(retry, dict) and retry.get("ok") and landed)
    sub_note = f"subscribe REFUSED {refused_sub.get('code')}" if refused_sub else f"{len(live)} live state event(s)"
    record(4, "Share a thing (local half)", ok,
           f"guest page HTTP {served}; credential given once at identify; {sub_note}; guest stale write: "
           f"{(stale or {}).get('code')}; retry: {'landed' if landed else (retry or {}).get('code', retry)}")


def scenario4(c):
    asyncio.run(_scenario4(c))


# ---------------------------------------------------------------------------------------------- 5
def instance_process(port):
    out = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], capture_output=True, text=True).stdout
    gw = int(out.split()[0])
    app = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(gw)], capture_output=True, text=True).stdout)
    exe = subprocess.run(["ps", "-o", "comm=", "-p", str(app)], capture_output=True, text=True).stdout.strip()
    env = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(app)], capture_output=True, text=True).stdout
    data = re.search(r"PORT42_DATA_DIR=(\S+)", env)
    return app, exe.split(".app/")[0] + ".app", data.group(1) if data else None


def restart(c):
    pid, bundle, data_dir = instance_process(c.port)
    os.kill(pid, signal.SIGTERM)
    for _ in range(40):
        try:
            os.kill(pid, 0)
            time.sleep(0.5)
        except ProcessLookupError:
            break
    env = dict(os.environ, PORT42_GATEWAY_PORT=str(c.port), **({"PORT42_DATA_DIR": data_dir} if data_dir else {}))
    subprocess.run(["open", bundle], env=env, check=True)
    for _ in range(90):
        if c.host_up():
            break
        time.sleep(1)
    time.sleep(4)   # let restore and any layout pass run before reading positions


def geometry(c, ids):
    return {p["id"]: (p.get("spaceId"), p.get("status"), p.get("x"), p.get("y"))
            for p in c.call("ports.list") if p["id"] in ids}


def scenario5(c, do_restart):
    home = c.call("space.current")["id"]
    others = [s["id"] for s in c.call("space.list") if s["id"] != home]
    away = others[0] if others else c.call("space.create", {"name": "harness-away"})["id"]
    placed = []
    for sid, base in ((home, 0), (away, 1)):
        c.call("space.switchTo", {"space_id": sid})
        time.sleep(1)
        for i in range(3):
            p = made(c.call("port.create", {"type": "web", "title": f"harness: s5 {base * 3 + i}",
                                            "html": page(f"<h1>{base * 3 + i}</h1>")}))
            x, y = 60 + i * 420, 60 + base * 300
            c.call("port.move", {"id": p["id"], "x": x, "y": y, "space_id": sid,
                                 "token": next(q for q in c.call("ports.list") if q["id"] == p["id"])["token"]})
            placed.append(p["id"])
    for pid in (placed[2], placed[5]):
        c.call("port.manage", {"id": pid, "action": "minimize",
                               "token": next(q for q in c.call("ports.list") if q["id"] == pid)["token"]})
    c.call("space.switchTo", {"space_id": home})
    time.sleep(1)
    arranged = geometry(c, placed)
    newcomer = made(c.call("port.create", {"type": "web", "title": "harness: s5 newcomer", "html": page("<h1>new</h1>")}))
    time.sleep(1)
    after_spawn = geometry(c, placed)
    moved_by_spawn = [k[:8] for k in placed if arranged[k] != after_spawn[k]]
    notes = [f"6 placed across 2 spaces, 2 parked; adding a port moved {len(moved_by_spawn)} {moved_by_spawn or ''}"]
    ok = not moved_by_spawn
    # Closing archives (Phase 2 step 2): the port leaves the listing, is listed closed, and reopens as
    # itself at its position, moving nothing else.
    victim = placed[0]
    c.call("port.manage", {"id": victim, "action": "close",
                           "token": next(q for q in c.call("ports.list") if q["id"] == victim)["token"]})
    gone = all(q["id"] != victim for q in c.call("ports.list"))
    listed_closed = any(q["id"] == victim and q.get("status") == "closed"
                        for q in c.call("ports.list", {"include_closed": True}))
    c.call("port.reopen", {"id": victim})
    time.sleep(1)
    after_reopen = geometry(c, placed)
    moved_by_reopen = [k[:8] for k in placed if after_reopen[k] != after_spawn[k]]
    reopen_ok = gone and listed_closed and not moved_by_reopen
    notes.append(f"close+reopen: {'same port, same place' if reopen_ok else f'gone={gone} closed={listed_closed} moved={moved_by_reopen}'}")
    ok = ok and reopen_ok
    if do_restart:
        restart(c)
        after = geometry(c, placed + [newcomer["id"]])
        before = dict(after_spawn, **{newcomer["id"]: geometry(c, [newcomer["id"]]).get(newcomer["id"])})
        moved = [k[:8] for k in placed if after.get(k) != after_spawn[k]]
        notes.append(f"restart moved {len(moved)} {moved or ''}")
        ok = ok and not moved
    else:
        notes.append("restart skipped (--no-restart)")
    record(5, "Arrange things", ok, "; ".join(notes))


# ---------------------------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4245)
    ap.add_argument("--only", default="1,2,3,4,5")
    ap.add_argument("--agent", help="an existing companion to ask instead of a fresh session")
    ap.add_argument("--cli", default="claude", help="the CLI a fresh session runs (claude or codex)")
    ap.add_argument("--no-restart", action="store_true")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    c = Client(a.port, os.environ.get("P42_TOKEN_FILE"))
    if not c.host_up():
        sys.exit(f"no Port42 answering on {a.port}")
    runs = {1: lambda: scenario1(c, a.agent, a.cli), 2: lambda: scenario2(c), 3: lambda: scenario3(c),
            4: lambda: scenario4(c), 5: lambda: scenario5(c, not a.no_restart)}
    names = {1: "Make a thing", 2: "Drive a thing", 3: "Compose things", 4: "Share a thing (local half)",
             5: "Arrange things"}
    for n in [int(x) for x in a.only.split(",")]:
        try:
            runs[n]()
        except Exception as e:
            record(n, names[n], False, f"harness error: {type(e).__name__}: {e}")
    if not a.keep:
        # Closing archives, so the harness closes AND deletes what it made. A port is found by id, or
        # by title when the id port.create returned is not the one ports.list shows (terminals).
        def clean(pid):
                listed = c.call("ports.list")
                q = next((q for q in listed if q["id"] == pid), None) \
                    or next((q for q in listed if TITLES.get(pid) and q["title"] == TITLES[pid]), None)
                if q:
                    c.call("port.manage", {"id": q["id"], "action": "close", "token": q["token"]})
                    c.call("port.delete", {"id": q["id"]})
                elif any(r["id"] == pid for r in c.call("ports.list", {"include_closed": True})):
                    c.call("port.delete", {"id": pid})
        # Cleanup runs straight after scenario 5 restarts the instance, so a call can land before it
        # answers again: one retry after a pause.
        for pid in MADE:
            for attempt in (1, 2):
                try:
                    clean(pid)
                    break
                except Exception as e:
                    if attempt == 2:
                        print(f"cleanup: {TITLES.get(pid) or pid}: {e}", file=sys.stderr)
                    time.sleep(3)
    width = max(len(r[1]) for r in RESULTS)
    for n, name, status, ev in RESULTS:
        print(f"{n}  {name:<{width}}  {status:<4}  {ev}")
    sys.exit(1 if any(r[2] == "FAIL" for r in RESULTS) else 0)


if __name__ == "__main__":
    main()
