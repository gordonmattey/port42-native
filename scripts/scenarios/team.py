#!/usr/bin/env python3
"""A lead with a vision and two engineers build one port together through its chat.

    P42_TOKEN_FILE=~/.port42/port42dev3/tokens/nautilus-harness \
        scripts/scenarios/team.py --port 4245 [--rounds 3]

GM (2026-09-25): one reviewer "kinda gasses out"; have two engineers and a lead pushing forward with
a vision. The harness only starts it: it asks the lead in a new space's chat. From there the agents
run themselves in the port's chat, by @mention. The lead sets the vision, gives both engineers work
each round, checks what they did, and pushes further, then posts DONE. The harness watches: the port
appears, it changes every round, both engineers take part in the port's chat, the lead finishes, and
the console stays clean. Two engineers writing one port also exercises the stale-write retry.

A live monitor port, "harness: team", shows each step. Everything is left in place to inspect.
"""
import argparse, os, sys, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from p42 import Client  # noqa: E402
from collaborate import Run, wait_for, companion, console_errors, chat_after  # noqa: E402


def html_of(c, pid):
    h = c.call("port.getHtml", {"id": pid})
    return h.get("html", h) if isinstance(h, dict) else h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4245)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=2400, help="seconds for the whole team run")
    a = ap.parse_args()
    c = Client(a.port, os.environ.get("P42_TOKEN_FILE"))
    space = c.call("space.create", {"name": "team-" + uuid.uuid4().hex[:4], "switch": True})["id"]
    time.sleep(1)
    run = Run(c, title="harness: team")
    title = "harness team shader " + uuid.uuid4().hex[:4]

    lead, eng1, eng2 = "harness-t-lead", "harness-t-eng1", "harness-t-eng2"
    for t, cmd in (("harness: t lead", "claude"), ("harness: t eng1", "claude"), ("harness: t eng2", "codex")):
        c.call("port.create", {"type": "terminal", "title": t, "command": cmd, "space_id": space}, timeout=120)
    run.say("wait", "opened a lead (claude) and two engineers (claude, codex)")
    for name in (lead, eng1, eng2):
        ok = wait_for(lambda n=name: companion(c, n), 120, every=3)
        run.say("pass" if ok else "fail", f"@{name} registered" if ok else f"@{name} never registered")
        if not ok:
            return finish(run)

    brief = (
        f"@{lead} you lead a small team: @{eng1} and @{eng2} are your engineers. Goal: a web port titled "
        f"'{title}', a WebGL shader piece people would stop and stare at. First set an ambitious vision. "
        f"Then have @{eng1} build the first version. Then run {a.rounds} rounds in THE PORT'S OWN CHAT: each "
        f"round, give both engineers concrete, ambitious next steps toward the vision (split the work so they "
        f"do not edit the same part), check what they did actually works, and push further. Tell them to "
        f"report back to you with @{lead} when done. When the {a.rounds} rounds are finished, post a message "
        f"in the port's chat that starts with DONE and says what the port now is.")
    ask = c.call("chat.post", {"port": space, "text": brief})
    started = time.time()
    run.say("wait", f"briefed @{lead} in the space chat ({a.rounds} rounds)")

    port = wait_for(lambda: next((p for p in c.call("ports.list") if p.get("title") == title), None), 900)
    if not port:
        run.say("fail", f"no port titled '{title}' within 900s")
        return finish(run)
    run.say("pass", f"'{title}' appeared after {time.time() - started:.0f}s")
    pid = port["id"]

    # Watch until the lead says DONE or time runs out: count distinct versions and who spoke.
    seen, versions, last = set(), 0, html_of(c, pid)
    done = None
    deadline = started + a.timeout
    while time.time() < deadline and not done:
        time.sleep(10)
        now = html_of(c, pid)
        if now != last:
            versions += 1
            last = now
            run.say("wait", f"version change {versions} after {time.time() - started:.0f}s")
        for e in c.call("chat.read", {"port": pid, "limit": 200})["entries"]:
            who = e["from"]["name"]
            if who not in seen and who in (lead, eng1, eng2):
                seen.add(who)
                run.say("wait", f"@{who} is talking in the port's chat")
            if who == lead and e["text"].lstrip().upper().startswith("DONE"):
                done = e
    elapsed = time.time() - started
    run.say("pass" if versions >= a.rounds else "fail", f"the port changed {versions} time(s) after the first version")
    for name in (lead, eng1, eng2):
        run.say("pass" if name in seen else "fail",
                f"@{name} worked in the port's chat" if name in seen else f"@{name} never spoke in the port's chat")
    run.say("pass" if done else "fail",
            f"@{lead} finished after {elapsed:.0f}s: {done['text'][:140]!r}" if done
            else f"@{lead} did not post DONE within {a.timeout}s")
    errs = console_errors(c, pid)
    run.say("pass" if not errs else "fail",
            "final version: no console errors" if not errs else f"final version logged {len(errs)} error(s): {errs[0].get('message', '')[:80]}")
    space_replies = chat_after(c, space, ask["entry"]["seq"], lead)
    run.say("pass" if space_replies and any(pid in e["text"] for e in space_replies) else "fail",
            "the lead answered in the space chat with the port's id" if space_replies else "the lead never answered in the space chat")
    return finish(run)


def finish(run):
    fails = [r for r in run.results if r[0] == "fail"]
    run.say("pass" if not fails else "fail", f"done: {len(run.results) - len(fails)} passed, {len(fails)} failed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
