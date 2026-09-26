#!/usr/bin/env python3
"""Run Port42's golden eval set against a DEV instance and record what each run cost.

    scripts/evals/run_evals.py                      # print the plan; touches nothing
    P42_TOKEN_FILE=~/.port42/port42dev4/tokens/nautilus-prime \\
        scripts/evals/run_evals.py --port 4246 --label skills --repeat 3 --run

Each task has a fixed amount of work and deterministic checks (golden.json). Every run gets its own
space and its own agents, made hidden through `companions.create`; the agents are asked in chat,
exactly as a person would ask them. When the task's end condition is met (or it times out), the
checks run and each agent's tokens are read from its own session files (usage.py). One JSON line per
run goes to results/<label>-<time>.jsonl; compare.py sets two labels side by side.

Never on prod: port 4242 is refused. Costs real agent turns; nothing runs without --run.
"""
import argparse, json, os, re, sys, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scenarios"))
sys.path.insert(0, HERE)
import usage  # noqa: E402

DEV_LOGS = {4243: "Port42Dev", 4244: "Port42Dev2", 4245: "Port42Dev3", 4246: "Port42Dev4"}


def load_tasks():
    with open(os.path.join(HERE, "golden.json")) as fh:
        return json.load(fh)["tasks"]


def expand(tasks, only, clis):
    """(task, variant) pairs: a solo task runs once per CLI it lists; a mixed task once as written."""
    out = []
    for t in tasks:
        if only and t["id"] not in only:
            continue
        variants = t.get("clis") or [None]
        for cli in variants:
            if clis and cli and cli not in clis:
                continue
            out.append((t, cli))
    return out


def fill(text, names, title, tag):
    s = text.replace("{title}", title).replace("{tag}", tag)
    for role, name in names.items():
        s = s.replace("{" + role + "}", name)
    return s


class Run:
    def __init__(self, c, task, cli, tag, log_path):
        self.c, self.task, self.cli, self.tag, self.log_path = c, task, cli, tag, log_path
        self.title = task["title"].replace("{tag}", tag)
        self.names = {a["role"]: f"{a['role']}-{tag}" for a in task.get("agents", [])}
        self.space = None
        self.ask_seq = 0

    # ---- lookups -------------------------------------------------------------------------------
    def port(self, title):
        return next((p for p in self.c.call("ports.list") if p.get("title") == title), None)

    def chat_key(self, where):
        if where == "space":
            return self.space
        if where.startswith("port:"):
            p = self.port(fill(where[5:], self.names, self.title, self.tag))
            return p["id"] if p else None
        return None

    def entries(self, where, after=0):
        if isinstance(where, list):                              # several chats, read together
            return [e for w in where for e in self.entries(w, after if w == "space" else 0)]
        key = self.chat_key(where)
        if not key:
            return []
        return self.c.call("chat.read", {"port": key, "after": after, "limit": 200})["entries"]

    def condition(self, cond):
        who = self.names.get(cond.get("reply_from") or cond.get("from"))
        where = cond["in"]
        for e in self.entries(where, self.ask_seq):
            if e["from"]["name"] != who:
                continue
            if "message_starts" in cond and not e["text"].lstrip().upper().startswith(cond["message_starts"]):
                continue
            return True
        return False

    def wait(self, cond, deadline):
        while time.time() < deadline:
            if self.condition(cond):
                return True
            time.sleep(5)
        return False

    # ---- the run -------------------------------------------------------------------------------
    def setup(self):
        if "imagine" in self.task:
            # /imagine makes its own space, team and brief; the names and title come back from it.
            im = self.task["imagine"]
            r = self.c.call("imagine.start", {"line": im["line"].replace("{tag}", self.tag),
                                              "versions": im["versions"]}, timeout=180)
            self.space, self.title = r["space"], r["title"]
            self.names = {"lead": r["lead"], "eng1": r["eng1"], "eng2": r["eng2"]}
            return
        self.space = self.c.call("space.create", {"name": f"eval-{self.task['id']}-{self.tag}"})["id"]
        for a in self.task["agents"]:
            cli = a.get("cli") or self.cli
            self.c.call("companions.create", {"name": self.names[a["role"]], "agent": cli, "runs": "hidden",
                                              "space_id": self.space}, timeout=120)
        end = time.time() + 180
        while time.time() < end:
            roster = {(x.get("name") or x.get("displayName")) for x in self.c.call("companions.list", {"space_id": "*"})}
            if all(n in roster for n in self.names.values()):
                break
            time.sleep(3)
        for step in self.task.get("setup", []):
            if "make_port" in step:
                m = step["make_port"]
                self.c.call("port.create", {"type": "web", "title": fill(m["title"], self.names, self.title, self.tag),
                                            "html": fill(m["html"], self.names, self.title, self.tag),
                                            "space_id": self.space})

    def act(self, deadline):
        if "imagine" in self.task:                               # the brief was the ask
            return self.wait(self.task["done_when"], deadline)
        ask = self.task["ask"]
        r = self.c.call("chat.post", {"port": self.space, "text": fill(ask["text"], self.names, self.title, self.tag)})
        self.ask_seq = r["entry"]["seq"]
        for step in self.task.get("then", []):
            if "wait_for" in step and not self.wait(step["wait_for"], deadline):
                return False
            if "break_port" in step:
                b = step["break_port"]
                p = self.port(fill(b["title"], self.names, self.title, self.tag))
                self.c.call("port.update", {"id": p["id"], "html": fill(b["html"], self.names, self.title, self.tag),
                                            "token": p["token"]})
        return self.wait(self.task["done_when"], deadline)

    def check(self, ck):
        t = fill(ck.get("title", ""), self.names, self.title, self.tag)
        kind = ck["type"]
        p = self.port(t) if t else None
        if kind == "port_exists":
            return p is not None, t
        if kind == "single_port":
            n = sum(1 for q in self.c.call("ports.list") if q.get("title") == t)
            return n == 1, f"{n} ports titled '{t}'"
        if kind != "watching" and kind != "spoke_in" and p is None:
            return False, f"no port '{t}'"
        if kind == "versions":
            h = self.c.call("port.history", {"id": p["id"]})
            n = len(h) if isinstance(h, list) else 0
            return ck["min"] <= n <= ck["max"], f"{n} versions"
        if kind == "console_clean":
            r = self.c.call("port.console", {"id": p["id"], "tail": 200})
            lines = r.get("lines", r) if isinstance(r, dict) else r
            errs = [l for l in (lines or []) if isinstance(l, dict) and l.get("level") == "error"]
            return not errs, f"{len(errs)} console errors"
        if kind in ("dom_contains", "dom_lacks", "dom_matches"):
            if ck.get("wait"):
                time.sleep(ck["wait"])
            d = self.c.call("port.getDom", {"id": p["id"]})
            html = d.get("html", "") if isinstance(d, dict) else str(d)
            if kind == "dom_contains":
                missing = [x for x in ck["text"] if x not in html]
                return not missing, f"missing {missing}" if missing else "all present"
            if kind == "dom_lacks":
                present = [x for x in ck["text"] if x in html]
                return not present, f"still has {present}" if present else "none present"
            return re.search(ck["pattern"], html) is not None, "matched" if re.search(ck["pattern"], html) else "no match"
        if kind == "status":
            return p.get("status") == ck["is"], f"status {p.get('status')}"
        if kind == "watching":
            who = self.names[ck["who"]]
            ws = self.c.call("companions.watches", {"companion": who})
            ok = any(w.get("title") == t for w in ws)
            return ok, f"{who} watches '{t}'" if ok else f"{who} does not watch '{t}'"
        if kind == "spoke_in":
            said = {e["from"]["name"] for e in self.entries(ck["in"])}
            missing = [self.names[r] for r in ck["who"] if self.names[r] not in said]
            return not missing, f"silent: {missing}" if missing else "all spoke"
        return False, f"unknown check {kind}"

    def tokens(self):
        try:
            text = open(self.log_path, errors="replace").read()
        except OSError:
            return {}
        return {role: usage.agent_usage(text, name) for role, name in self.names.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4246)
    ap.add_argument("--task", action="append", help="task id (repeatable); default all")
    ap.add_argument("--cli", action="append", help="for solo tasks: claude and/or codex; default both")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--label", default="run", help="what is being measured, e.g. 'skills' or 'old-brief'")
    ap.add_argument("--log", help="the instance's log (default ~/port42-build/<instance>.log)")
    ap.add_argument("--run", action="store_true", help="actually run; without it, print the plan")
    a = ap.parse_args()

    plan = expand(load_tasks(), set(a.task or []), set(a.cli or []))
    print(f"{len(plan)} task variant(s) x {a.repeat} = {len(plan) * a.repeat} run(s) on port {a.port}, label '{a.label}':")
    for t, cli in plan:
        who = ", ".join(f"{g['role']}={g.get('cli') or cli}" for g in t.get("agents", [])) or "imagine team"
        print(f"  {t['id']:<14} {who:<44} timeout {t['timeout']}s   {t['summary']}")
    if not a.run:
        print("\nNothing ran. Add --run to run it (costs real agent turns).")
        return
    if a.port == 4242:
        sys.exit("refused: 4242 is prod. Evals run on a dev instance.")
    from p42 import Client
    c = Client(a.port, os.environ.get("P42_TOKEN_FILE"))
    if not c.host_up():
        sys.exit(f"no Port42 answering on {a.port}")
    log_path = a.log or os.path.expanduser(f"~/port42-build/{DEV_LOGS.get(a.port, 'Port42Dev')}.log")
    out = os.path.join(HERE, "results", f"{a.label}-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    with open(out, "a") as fh:
        for rep in range(a.repeat):
            for t, cli in plan:
                tag = uuid.uuid4().hex[:4]
                r = Run(c, t, cli, tag, log_path)
                r.setup()
                start = time.time()
                done = r.act(start + t["timeout"])
                wall = time.time() - start
                time.sleep(8)                                        # let the last write and hook land
                checks = [{"check": ck["type"], "ok": ok, "detail": d} for ck in t["checks"] for ok, d in [r.check(ck)]]
                tok = r.tokens()
                main_port = r.port(r.title)
                hist = c.call("port.history", {"id": main_port["id"]}) if main_port else []
                versions = len(hist) if isinstance(hist, list) else 0
                total = sum(u.get("total", 0) for u in tok.values())
                rec = {"label": a.label, "task": t["id"], "cli": cli or "mixed", "rep": rep, "tag": tag,
                       "done": done, "passed": done and all(x["ok"] for x in checks), "wall_s": round(wall, 1),
                       "versions": versions, "tokens_total": total, "agents": tok, "checks": checks,
                       "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
                fh.write(json.dumps(rec) + "\n"); fh.flush()
                print(f"{t['id']:<14} {rec['cli']:<6} rep {rep}  {'PASS' if rec['passed'] else 'FAIL'}  "
                      f"{wall:6.0f}s  {total:>10,} tokens  {versions} versions")
    print(f"\nresults: {out}")


if __name__ == "__main__":
    main()
