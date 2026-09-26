#!/usr/bin/env python3
"""/imagine, live: one line becomes a team that builds a port to DONE within its version budget.

    P42_TOKEN_FILE=~/.port42/port42dev4/tokens/nautilus-prime \
        scripts/scenarios/imagine.py --port 4246 [--versions 10]

The harness does what ⌘I and a chat's /imagine do: it calls imagine.start with a fixed line. From
there Port42 makes the space, the three agents (visible, with their roles) and the brief, and the
agents run themselves. The harness watches: the port appears under the title taken from the line,
it never goes past the budget, every agent speaks, the lead answers in the space's chat and posts
DONE (the team coordinates in the space's chat and works together in the port's), nobody posts into
another's terminal chat, and the console is clean. The team is left running: /imagine is a
bootstrap, and nothing closes its terminals.

Needs the `terminal` grant for the harness client. A live monitor port, "harness: imagine", shows
each step. The space and its port are left in place to inspect.
"""
import argparse, os, sys, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from p42 import Client  # noqa: E402
from collaborate import Run, wait_for, console_errors, chat_after  # noqa: E402

LINE = "({tag}) a starfield you can steer with the mouse, with a speed control"  # the tag first: the title keeps 60 chars


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4246)
    ap.add_argument("--versions", type=int, default=10, help="the budget; 10 is what a person gets")
    ap.add_argument("--timeout", type=int, default=2400, help="seconds for the whole run")
    a = ap.parse_args()
    if a.port == 4242:
        sys.exit("refused: 4242 is prod. The harness runs on a dev instance.")
    c = Client(a.port, os.environ.get("P42_TOKEN_FILE"))
    run = Run(c, title="harness: imagine")

    line = LINE.format(tag=uuid.uuid4().hex[:4])
    team = c.call("imagine.start", {"line": line, "versions": a.versions}, timeout=180)
    space, lead, eng1, eng2, title = team["space"], team["lead"], team["eng1"], team["eng2"], team["title"]
    members = (lead, eng1, eng2)
    started = time.time()
    run.say("pass" if team["versions"] == a.versions else "fail",
            f"imagined '{title}': lead @{lead}, engineers @{eng1} and @{eng2}, budget {team['versions']}")

    brief = c.call("chat.read", {"port": space, "after": 0, "limit": 5})["entries"]
    first = brief[0] if brief else None
    run.say("pass" if first and first["text"].startswith(f"@{lead} /imagine from ") and line in first["text"] else "fail",
            "the brief is the space's first post, to the lead, with the line verbatim" if first else "no brief posted")

    port = wait_for(lambda: next((p for p in c.call("ports.list") if p.get("title") == title), None), 900)
    if not port:
        run.say("fail", f"no port titled '{title}' within 900s")
        return finish(run)
    run.say("pass", f"'{title}' appeared after {time.time() - started:.0f}s")

    def mine():
        return [p["id"] for p in c.call("ports.list") if p.get("title") == title]

    seen, done, most = set(), None, 0
    deadline = started + a.timeout
    while time.time() < deadline and not done:
        time.sleep(10)
        for pid in mine():
            n = len(c.call("port.history", {"id": pid}))
            if n > most:
                most = n
                run.say("wait", f"version {n} of {a.versions} after {time.time() - started:.0f}s")
        # The team coordinates in the space's chat and works together in the port's (GM, 2026-09-26).
        for key, where in [(space, "the space's chat")] + [(pid, "the port's chat") for pid in mine()]:
            for e in c.call("chat.read", {"port": key, "limit": 200})["entries"]:
                who = e["from"]["name"]
                if who in members and who not in seen:
                    seen.add(who)
                    run.say("wait", f"@{who} is talking in {where}")
                if who == lead and e["text"].lstrip().upper().startswith("DONE"):
                    done = e
    elapsed = time.time() - started
    copies = mine()
    run.say("pass" if len(copies) == 1 else "fail",
            "one port, no duplicate" if len(copies) == 1 else f"{len(copies)} ports share the title")
    run.say("pass" if 1 <= most <= a.versions else "fail", f"{most} version(s), budget {a.versions}")
    for name in members:
        run.say("pass" if name in seen else "fail",
                f"@{name} spoke in the space's or the port's chat" if name in seen
                else f"@{name} never spoke in the space's or the port's chat")
    run.say("pass" if done else "fail",
            f"@{lead} posted DONE after {elapsed:.0f}s: {done['text'][:140]!r}" if done
            else f"@{lead} did not post DONE within {a.timeout}s")
    errs = [e for p in copies for e in console_errors(c, p)]
    run.say("pass" if not errs else "fail",
            "final version: no console errors" if not errs else f"final version logged {len(errs)} error(s): {errs[0].get('message', '')[:80]}")
    replies = chat_after(c, space, first["seq"] if first else 0, lead)
    run.say("pass" if replies else "fail",
            f"the lead coordinated in the space's chat: {replies[0]['text'][:100]!r}" if replies
            else "the lead never posted in the space's chat")
    # No team talk in terminal chats: the person follows the space's and the port's chats.
    term = [p["id"] for p in c.call("ports.list") if p.get("title") in members]
    stray = [e for t in term for e in c.call("chat.read", {"port": t, "limit": 200})["entries"]
             if e["from"]["name"] in members and e["from"]["name"] != next((p["title"] for p in c.call("ports.list") if p["id"] == t), None)]
    run.say("pass" if not stray else "fail",
            "no teammate posted into another's terminal chat" if not stray
            else f"{len(stray)} post(s) in another companion's terminal chat, e.g. {stray[0]['from']['name']}: {stray[0]['text'][:80]!r}")

    # /imagine is a bootstrap: the team is ordinary companions now, and is always left running.
    run.say("wait", f"the team stays in space {space} ('{title}')")
    return finish(run)


def finish(run):
    fails = [r for r in run.results if r[0] == "fail"]
    run.say("pass" if not fails else "fail", f"done: {len(run.results) - len(fails)} passed, {len(fails)} failed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
