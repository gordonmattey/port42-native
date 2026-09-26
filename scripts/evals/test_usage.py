"""Tests for usage.py on small synthetic transcripts. Run: python3 -m unittest scripts/evals/test_usage.py"""
import json
import os
import tempfile
import unittest

import usage


def write(path, records):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in records:
            fh.write(json.dumps(r) + "\n")


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="p42 usage ")          # a space in the path, like Application Support
        self.claude = os.path.join(self.root, ".claude/projects/x/a.jsonl")
        write(self.claude, [
            {"type": "user", "message": {"content": "hi"}},
            {"type": "assistant", "message": {"usage": {"input_tokens": 3, "cache_read_input_tokens": 100,
                                                        "cache_creation_input_tokens": 10, "output_tokens": 7}}},
            {"type": "assistant", "message": {"usage": {"input_tokens": 1, "cache_read_input_tokens": 200,
                                                        "cache_creation_input_tokens": 0, "output_tokens": 3}}},
        ])
        sessions = os.path.join(self.root, "codex-home/sessions")
        self.codex1 = os.path.join(sessions, "r1.jsonl")
        self.codex2 = os.path.join(sessions, "r2.jsonl")
        tc = lambda i, c, o: {"payload": {"type": "token_count", "info": {"total_token_usage":
                                         {"input_tokens": i, "cached_input_tokens": c, "output_tokens": o}}}}
        write(self.codex1, [tc(100, 80, 5), tc(300, 250, 9)])     # running total for this file: last one counts
        write(self.codex2, [tc(50, 40, 2)])
        # The same sessions folder under a second path, as the Codex home's link to ~/.codex/sessions.
        self.alias = os.path.join(self.root, "alias-sessions")
        os.symlink(sessions, self.alias)
        other = os.path.join(sessions, "someone-else.jsonl")
        write(other, [tc(9999, 0, 999), {"note": "mentions coder-bee in a companion list"}])
        self.log = (
            f"[hooks] turnComplete: transcript={self.claude} bytes=1\n x [ctl:maker-bee] event=turnComplete\n"
            f"[hooks] turnComplete: transcript={self.claude} bytes=1\n x [ctl:maker-bee] event=turnComplete\n"
            f"[hooks] turnComplete: transcript={self.codex1} bytes=1\n x [ctl:coder-bee] event=turnComplete\n"
            f"[hooks] turnComplete: transcript={os.path.join(self.alias, 'r1.jsonl')} bytes=1\n x [ctl:coder-bee] e\n"
            f"[hooks] turnComplete: transcript={self.codex2} bytes=1\n x [ctl:coder-bee] event=turnComplete\n"
        )

    def test_claude_sums_every_call(self):
        u = usage.agent_usage(self.log, "maker-bee")
        self.assertEqual((u["calls"], u["input"], u["cache_read"], u["cache_write"], u["output"]), (2, 4, 300, 10, 10))
        self.assertEqual(u["files"], 1)
        self.assertEqual(u["cli"], "claude")

    def test_codex_last_total_per_file_summed_and_aliases_counted_once(self):
        u = usage.agent_usage(self.log, "coder-bee")
        self.assertEqual(u["files"], 2, "the linked path must resolve to the same file")
        self.assertEqual(u["cache_read"], 250 + 40)
        self.assertEqual(u["input"], (300 - 250) + (50 - 40))
        self.assertEqual(u["output"], 9 + 2)
        self.assertEqual(u["cli"], "codex")

    def test_only_own_files_count(self):
        u = usage.agent_usage(self.log, "coder-bee")
        self.assertLess(u["total"], 9999, "a file that only mentions the name was counted")

    def test_paths_with_spaces(self):
        self.assertIn(" ", self.claude)
        self.assertEqual(usage.own_transcripts(self.log, "maker-bee"), [os.path.realpath(self.claude)])


if __name__ == "__main__":
    unittest.main()
