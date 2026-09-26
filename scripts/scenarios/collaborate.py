#!/usr/bin/env python3
"""Two agents build and improve a port through its chat, end to end, on a live Port42 instance.

    P42_TOKEN_FILE=~/.port42/port42dev3/tokens/nautilus-harness \
        scripts/scenarios/collaborate.py --port 4245

GM's scenario (2026-09-25): ask a Claude companion in the space chat for a shader port; once the first
version is up, bring a Codex companion in through the PORT'S chat to review it and make it 100x
better; both must finish on their own. The run shows itself on the desktop as a port, "harness:
collaborate", with every step, its time, and pass or fail. The shader port and both terminals are
left in place so the result and the sessions can be inspected.

Costs real agent turns on both CLIs. Needs the harness client's `terminal` grant on port 0.
"""
import argparse, html, os, re, sys, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from p42 import Client, Refused  # noqa: E402

MONITOR = """<title>harness: collaborate</title>
<style>body{background:#0b0d10;color:#9fe;font:13px ui-monospace,monospace;margin:14px}
h1{font-size:14px;color:#0fa;margin:0 0 10px}.pass{color:#4f8}.fail{color:#f66}.wait{color:#fc6}
li{margin:3px 0;list-style:none}</style>
<h1>two agents, one port, through its chat</h1><ul id="log"></ul>
<script>
const log = document.getElementById('log');
window.addEventListener('port42:data', e => {
  const d = typeof e.detail === 'string' ? JSON.parse(e.detail) : e.detail;
  const li = document.createElement('li');
  li.className = d.status; li.textContent = d.line; log.appendChild(li);
});
</script>"""


class Run:
    def __init__(self, c):
        self.c = c
        self.t0 = time.time()
        self.monitor = c.call("port.create", {"type": "web", "title": "harness: collaborate", "html": MONITOR,
                                              "space_id": c.call("space.current")["id"]})
        self.results = []

    def say(self, status, line):
        stamp = f"{time.time() - self.t0:6.0f}s"
        text = f"{stamp}  {'✓' if status == 'pass' else '✗' if status == 'fail' else '…'}  {line}"
        print(text, flush=True)
        if status != "wait":
            self.results.append((status, line))
        try:
            tok = next(q["token"] for q in self.c.call("ports.list") if q["id"] == self.monitor["id"])
            import json
            self.c.call("port.push", {"id": self.monitor["id"], "data": json.dumps({"status": status, "line": text}),
                                      "token": tok})
        except Exception:
            pass


def wait_for(fn, timeout, every=5):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(every)
    return None


def companion(c, name):
    roster = c.call("companions.list", {"space_id": "*"})
    return any((x.get("name") or x.get("displayName")) == name for x in roster)


def console_errors(c, pid):
    try:
        lines = c.call("port.console", {"id": pid, "tail": 200})
    except Refused:
        return []
    lines = lines.get("lines", lines) if isinstance(lines, dict) else lines
    return [l for l in (lines or []) if isinstance(l, dict) and l.get("level") == "error"]


def chat_after(c, port, seq, frm):
    entries = c.call("chat.read", {"port": port, "after": seq, "limit": 200})["entries"]
    return [e for e in entries if e["from"]["name"].lower() == frm.lower()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4245)
    ap.add_argument("--make-timeout", type=int, default=480)
    ap.add_argument("--review-timeout", type=int, default=900)
    a = ap.parse_args()
    c = Client(a.port, os.environ.get("P42_TOKEN_FILE"))
    # A fresh space of its own, switched to so it can be watched (GM: do this in a new space).
    space = c.call("space.create", {"name": "collab-" + uuid.uuid4().hex[:4], "switch": True})["id"]
    time.sleep(1)
    run = Run(c)
    title = "harness shader " + uuid.uuid4().hex[:5]

    # 1. Two fresh agents, a Claude maker and a Codex reviewer, each in its own terminal port.
    maker, reviewer = "harness-c-maker", "harness-c-reviewer"
    c.call("port.create", {"type": "terminal", "title": "harness: c maker", "command": "claude",
                           "space_id": space}, timeout=120)
    c.call("port.create", {"type": "terminal", "title": "harness: c reviewer", "command": "codex",
                           "space_id": space}, timeout=120)
    run.say("wait", "opened a claude terminal (maker) and a codex terminal (reviewer)")
    for name in (maker, reviewer):
        ok = wait_for(lambda n=name: companion(c, n), 90, every=3)
        run.say("pass" if ok else "fail", f"@{name} registered as a companion" if ok else f"@{name} never registered")
        if not ok:
            return finish(run)

    # 2. Ask the maker in the space's chat.
    ask = c.call("chat.post", {"port": space, "text":
        f"@{maker} build a web port titled '{title}': a WebGL fragment shader of flowing, glowing color "
        f"bands that animates smoothly and fills the port. Check it works before you say it is done."})
    asked_at = time.time()
    run.say("wait", f"asked @{maker} in the space chat for '{title}'")
    port = wait_for(lambda: next((p for p in c.call("ports.list") if p.get("title") == title), None), a.make_timeout)
    if not port:
        run.say("fail", f"no port titled '{title}' within {a.make_timeout}s")
        return finish(run)
    run.say("pass", f"'{title}' appeared after {time.time() - asked_at:.0f}s")
    reply = wait_for(lambda: chat_after(c, space, ask["entry"]["seq"], maker), 180)
    run.say("pass" if reply else "fail",
            f"@{maker} replied in the space chat" if reply else f"@{maker} never replied in the space chat")
    if reply:
        named = any(port["id"] in e["text"] for e in reply)
        run.say("pass" if named else "fail",
                "its reply names the port's id, so the work can move to the port's chat" if named
                else "its reply does not name the port's id")
    errs = console_errors(c, port["id"])
    run.say("pass" if not errs else "fail",
            "first version: no console errors" if not errs else f"first version logged {len(errs)} error(s): {errs[0].get('message', '')[:80]}")
    v1 = c.call("port.getHtml", {"id": port["id"]})
    v1 = v1.get("html", v1) if isinstance(v1, dict) else v1

    # 3. Bring the reviewer in through the PORT's chat.
    review = c.call("chat.post", {"port": port["id"], "text":
        f"@{reviewer} review this port's code and make it 100x better. Update the port itself, check it "
        f"works, and report what you changed here in this chat."})
    asked_at = time.time()
    run.say("wait", f"asked @{reviewer} in the port's chat to review it and make it 100x better")

    def improved():
        now = c.call("port.getHtml", {"id": port["id"]})
        now = now.get("html", now) if isinstance(now, dict) else now
        return now != v1

    changed = wait_for(improved, a.review_timeout)
    run.say("pass" if changed else "fail",
            f"@{reviewer} updated the port after {time.time() - asked_at:.0f}s" if changed
            else f"@{reviewer} did not update the port within {a.review_timeout}s")
    said = wait_for(lambda: chat_after(c, port["id"], review["entry"]["seq"], reviewer), 240)
    run.say("pass" if said else "fail",
            f"@{reviewer} reported in the port's chat" if said else f"@{reviewer} never reported in the port's chat")
    if changed:
        errs = console_errors(c, port["id"])
        run.say("pass" if not errs else "fail",
                "improved version: no console errors" if not errs
                else f"improved version logged {len(errs)} error(s): {errs[0].get('message', '')[:80]}")
    return finish(run)


def finish(run):
    fails = [r for r in run.results if r[0] == "fail"]
    run.say("pass" if not fails else "fail",
            f"done: {len(run.results) - len(fails)} passed, {len(fails)} failed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
