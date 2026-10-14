#!/usr/bin/env python3
"""Tests for bin/run-cost.  Run: python3 tests/test_run_cost.py

What they pin down: subagent transcripts are counted; a reply split over several rows is counted once, from its
last row; a model with no price is "unpriced", not $0; a session id with no transcript is reported missing.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SRC = Path(os.environ.get("RUN_COST_SRC") or Path(__file__).resolve().parent.parent / "bin" / "run-cost")


def rec(mid, model, i=0, o=0, cr=0, w5=0, w1=0):
    return json.dumps({"type": "assistant", "message": {"id": mid, "model": model, "usage": {
        "input_tokens": i, "output_tokens": o, "cache_read_input_tokens": cr,
        "cache_creation_input_tokens": w5 + w1,
        "cache_creation": {"ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1}}}})


class RunCostTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="runcost-"))
        self.proj = self.tmp / "projects" / "-home-user-project"
        (self.proj / "S1" / "subagents").mkdir(parents=True)
        (self.proj / "S1.jsonl").write_text("\n".join([
            rec("m1", "claude-opus-5-5", i=1_000_000),            # $4
            rec("m1", "claude-opus-5-5", i=1_000_000),            # same reply, second row: not counted twice
            json.dumps({"type": "user", "message": {"content": "x"}}),
        ]) + "\n")
        (self.proj / "S1" / "subagents" / "agent-a.jsonl").write_text(
            rec("m2", "claude-sonnet-5", o=1_000_000) + "\n")    # $10
        self.ledger = self.tmp / "run-cost.jsonl"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cost(self, sid, *args, **env_extra):
        env = {k: v for k, v in os.environ.items() if k != "RUN_COST_PRICES"}
        env.update(RUN_COST_PROJECTS=str(self.tmp / "projects"), RUN_COST_LEDGER=str(self.ledger), **env_extra)
        p = subprocess.run([sys.executable, str(SRC), sid, *args], env=env, text=True, capture_output=True, timeout=30)
        self.assertEqual(0, p.returncode)
        return p.stdout, json.loads(self.ledger.read_text().splitlines()[-1])

    def test_main_plus_subagents_deduped(self):
        out, row = self.run_cost("S1", "--unit", "dispatch-x", "--attempt", "2", "--rc", "0")
        self.assertAlmostEqual(14.0, row["usd"])
        self.assertEqual(1, row["models"]["claude-opus-5-5"]["calls"])
        self.assertEqual(1_000_000, row["models"]["claude-opus-5-5"]["in"])
        self.assertIn("claude-sonnet-5", row["models"])
        self.assertEqual("2", row["attempt"])
        self.assertIn("$14.00", out)
        self.assertIn("1 subagent files", out)

    def test_split_message_takes_last_row(self):
        # a split reply's output grows row by row; taking the first row would undercount
        (self.proj / "S4.jsonl").write_text("\n".join([
            rec("m9", "claude-opus-5-5", i=1_000_000, o=10),
            rec("m9", "claude-opus-5-5", i=1_000_000, o=1_000_000),
        ]) + "\n")
        _, row = self.run_cost("S4")
        t = row["models"]["claude-opus-5-5"]
        self.assertEqual((1, 1_000_000, 1_000_000), (t["calls"], t["in"], t["out"]))
        self.assertAlmostEqual(24.0, row["usd"])

    def test_cache_write_1h_priced_apart(self):
        (self.proj / "S2.jsonl").write_text(rec("x", "claude-opus-5-5", w1=1_000_000) + "\n")
        _, row = self.run_cost("S2")
        self.assertAlmostEqual(8.0, row["usd"])

    def test_unknown_model_is_unpriced_not_zero(self):
        (self.proj / "S3.jsonl").write_text(rec("x", "claude-mystery-9", i=5) + "\n")
        out, row = self.run_cost("S3")
        self.assertIsNone(row["models"]["claude-mystery-9"]["usd"])
        self.assertEqual(["claude-mystery-9"], row["unpriced"])
        self.assertIn("unpriced", out)

    def test_prefix_of_a_known_model_is_not_priced_as_it(self):
        # sonnet-5-5 is not sonnet-5: a substring match would silently price it with the older model's rates
        (self.proj / "S5.jsonl").write_text(rec("x", "claude-sonnet-5-5", i=1_000_000) + "\n")
        _, row = self.run_cost("S5")
        self.assertEqual(["claude-sonnet-5-5"], row["unpriced"])

    def test_date_suffix_ignored(self):
        (self.proj / "S6.jsonl").write_text(rec("x", "claude-haiku-4-5-20251001", o=1_000_000) + "\n")
        _, row = self.run_cost("S6")
        self.assertAlmostEqual(5.0, row["usd"])

    def test_price_file_overrides_and_extends(self):
        prices = self.tmp / "prices.json"
        prices.write_text(json.dumps({"sonnet-5-5": [3, 15, .3, 3.75, 6], "claude-opus-5-5": [1, 1, 1, 1, 1]}))
        (self.proj / "S7.jsonl").write_text("\n".join([
            rec("a", "claude-sonnet-5-5", i=1_000_000),
            rec("b", "claude-opus-5-5", i=1_000_000),
        ]) + "\n")
        _, row = self.run_cost("S7", RUN_COST_PRICES=str(prices))
        self.assertEqual([], row["unpriced"])
        self.assertAlmostEqual(4.0, row["usd"])

    def test_missing_sid(self):
        out, row = self.run_cost("nope")
        self.assertTrue(row["missing"])
        self.assertIn("missing", out)


if __name__ == "__main__":
    unittest.main()
