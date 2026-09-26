#!/usr/bin/env python3
"""Set two eval result files side by side.

    scripts/evals/compare.py results/old-brief-*.jsonl results/skills-*.jsonl

Per task and CLI: pass rate, and the median of wall time, total tokens and tokens per version, with
the ratio of B to A. Medians, because one slow or lucky run should not move the answer.
"""
import json, statistics, sys
from collections import defaultdict


def load(path):
    rows = defaultdict(list)
    with open(path) as fh:
        for line in fh:
            if line.strip():
                r = json.loads(line)
                rows[(r["task"], r["cli"])].append(r)
    return rows


def summary(rs):
    per_version = [r["tokens_total"] / r["versions"] for r in rs if r["versions"]]
    med = lambda xs: statistics.median(xs) if xs else 0
    return {"n": len(rs), "pass": sum(r["passed"] for r in rs) / len(rs) if rs else 0,
            "wall": med([r["wall_s"] for r in rs]), "tokens": med([r["tokens_total"] for r in rs]),
            "per_version": med(per_version)}


def ratio(b, a):
    return f"{b / a:.2f}x" if a else "n/a"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    A, B = load(sys.argv[1]), load(sys.argv[2])
    print(f"A = {sys.argv[1]}\nB = {sys.argv[2]}\n")
    print(f"{'task':<14} {'cli':<6} {'pass A':>7} {'pass B':>7} {'wall B/A':>9} {'tokens B/A':>11} {'per ver B/A':>12}   n A/B")
    for key in sorted(set(A) | set(B)):
        a, b = summary(A.get(key, [])), summary(B.get(key, []))
        print(f"{key[0]:<14} {key[1]:<6} {a['pass']:>7.0%} {b['pass']:>7.0%} {ratio(b['wall'], a['wall']):>9} "
              f"{ratio(b['tokens'], a['tokens']):>11} {ratio(b['per_version'], a['per_version']):>12}   {a['n']}/{b['n']}")


if __name__ == "__main__":
    main()
