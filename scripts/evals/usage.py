"""Token accounting for Port42 agents, from what the app and the CLIs write down.

Which files are an agent's own: the app logs the transcript path at the end of every turn, tagged
with the agent's name ("[hooks] turnComplete: transcript=<path>" then "[ctl:<name>] ..."). That is
the only reliable source. Searching session files for the name is NOT: other sessions mention it
(a companion list, a hand-off), and on a Port42 instance the Codex home links `sessions` to
~/.codex/sessions, so the same file appears under two paths. Both mistakes were made once (2026-09-26)
and gave numbers off by several times; `test_usage.py` pins the method.

Claude: every assistant record carries `usage`; a session's cost is their sum.
Codex: each resumed session is a new rollout file with its own id, and its `token_count` events carry
the running total FOR THAT FILE, so a session's cost is the last total of each of its files, summed.

Paths contain spaces ("Application Support"), so a path ends at ".jsonl", not at whitespace.
"""
import json
import os
import re

TURN = re.compile(r"\[hooks\] turnComplete: transcript=(.+?\.jsonl)[^\n]*\n[^\n]*\[ctl:([^\]]+)\]")


def own_transcripts(log_text, name):
    """The distinct transcript files the app logged for this agent's turns, symlinks resolved."""
    return sorted({os.path.realpath(p) for p, who in TURN.findall(log_text) if who == name})


def claude_usage(path):
    t = {"calls": 0, "input": 0, "cache_read": 0, "cache_write": 0, "output": 0}
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            msg = d.get("message") if isinstance(d.get("message"), dict) else None
            if d.get("type") != "assistant" or not msg or not msg.get("usage"):
                continue
            u = msg["usage"]
            t["calls"] += 1
            t["input"] += u.get("input_tokens", 0)
            t["cache_read"] += u.get("cache_read_input_tokens", 0)
            t["cache_write"] += u.get("cache_creation_input_tokens", 0)
            t["output"] += u.get("output_tokens", 0)
    return t


def codex_usage(path):
    """The last running total in one rollout file, as the same fields as `claude_usage`."""
    last, calls = None, 0
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            pl = d.get("payload") or {}
            if pl.get("type") == "token_count" and pl.get("info"):
                calls += 1
                last = pl["info"].get("total_token_usage") or last
    last = last or {}
    cached = last.get("cached_input_tokens", 0)
    return {"calls": calls, "input": last.get("input_tokens", 0) - cached, "cache_read": cached,
            "cache_write": 0, "output": last.get("output_tokens", 0)}


def is_codex(path):
    return "/.claude/" not in path


def agent_usage(log_text, name):
    """An agent's tokens across all its own session files, with the files and the CLI."""
    files = own_transcripts(log_text, name)
    tot = {"calls": 0, "input": 0, "cache_read": 0, "cache_write": 0, "output": 0}
    clis = set()
    for f in files:
        if not os.path.exists(f):
            continue
        u = codex_usage(f) if is_codex(f) else claude_usage(f)
        clis.add("codex" if is_codex(f) else "claude")
        for k in tot:
            tot[k] += u[k]
    tot["total"] = tot["input"] + tot["cache_read"] + tot["cache_write"] + tot["output"]
    tot["files"] = len(files)
    tot["cli"] = ",".join(sorted(clis)) or "unknown"
    return tot
