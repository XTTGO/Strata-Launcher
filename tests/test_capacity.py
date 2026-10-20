from __future__ import annotations

import unittest
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from launcher.benchmark.capacity import judge_capacity, run_capacity_probe
from launcher.benchmark.models import runtime_paths


def six_rows(cap: int = 131072) -> list[dict]:
    return [
        {"depth": depth, "repetition": repetition, "status": "success", "found": True,
         "prompt_tokens": 125000, "finish_reason": "stop"}
        for depth in (10, 50, 90)
        for repetition in (1, 2)
    ]


class CapacityJudgementTests(unittest.TestCase):
    def test_six_near_cap_hits_verify_tier(self):
        result = judge_capacity(six_rows(), 131072)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["actual_prompt_tokens_min"], 125000)
        self.assertEqual(result["actual_prompt_tokens_max"], 125000)

    def test_one_recall_miss_fails_tier(self):
        rows = six_rows()
        rows[3]["found"] = False
        self.assertEqual(judge_capacity(rows, 131072)["status"], "failed")

    def test_correct_answer_with_short_input_is_not_capacity_proof(self):
        rows = six_rows()
        rows[0]["prompt_tokens"] = 100000
        self.assertEqual(judge_capacity(rows, 131072)["status"], "insufficient")

    def test_missing_or_truncated_reply_is_not_capacity_proof(self):
        rows = six_rows()
        rows[0]["finish_reason"] = "length"
        self.assertEqual(judge_capacity(rows, 131072)["status"], "insufficient")
        self.assertEqual(judge_capacity(rows[:5], 131072)["status"], "insufficient")

    def test_probe_sends_six_distinct_real_requests_and_saves_evidence(self):
        class Client:
            def __init__(self):
                self.codes = []

            def chat(self, body):
                self.assert_request(body)
                marker = body["messages"][0]["content"].split("SECRET-CODE:")[1].splitlines()[0].strip()
                self.codes.append(marker)
                return ({"choices": [{"message": {"content": marker}, "finish_reason": "stop"}],
                         "usage": {"prompt_tokens": 31000, "completion_tokens": 4, "total_tokens": 31004}}, 1.2)

            def assert_request(self, body):
                assert body["cache_prompt"] is False
                assert body["temperature"] == 0
                assert body["reasoning_effort"] == "none"

        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            dirs = SimpleNamespace(prompts=root / "prompts", answers=root / "answers", cancel=root / "cancel.json")
            server = SimpleNamespace(snapshot=SimpleNamespace(model_id="demo-ctx-32k", model_name="Demo", path=root / "config.json"),
                                     sampler=SimpleNamespace(samples=[], summary=lambda start: {"sample_count": 0}))
            client = Client()
            rows = run_capacity_probe(client, server, dirs, runtime_paths().root, 1, "sample-run", 32768)
            self.assertEqual(len(rows), 6)
            self.assertEqual(len(set(client.codes)), 6)
            self.assertTrue(all(row["found"] for row in rows))
            self.assertEqual(judge_capacity(rows, 32768)["status"], "verified")
            self.assertEqual(len(list(dirs.prompts.glob("*.txt"))), 6)

    def test_probe_recovers_from_first_context_overflow_with_shorter_prompt(self):
        class Client:
            def __init__(self):
                self.calls = 0

            def chat(self, body):
                self.calls += 1
                if self.calls == 1:
                    raise RuntimeError("HTTP 400: context length exceeded")
                secret = body["messages"][0]["content"].split("SECRET-CODE:")[1].splitlines()[0].strip()
                return ({"choices": [{"message": {"content": secret}, "finish_reason": "stop"}],
                         "usage": {"prompt_tokens": 31000}}, 0.5)

        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            dirs = SimpleNamespace(prompts=root / "prompts", answers=root / "answers", cancel=root / "cancel.json")
            server = SimpleNamespace(snapshot=SimpleNamespace(model_id="demo-ctx-32k", model_name="Demo", path=root / "config.json"),
                                     sampler=SimpleNamespace(samples=[], summary=lambda start: {"sample_count": 0}))
            client = Client()
            rows = run_capacity_probe(client, server, dirs, runtime_paths().root, 1, "sample-run", 32768)
            self.assertEqual(len(rows), 6)
            self.assertEqual(client.calls, 7)
            self.assertEqual(rows[0]["attempts"], 2)

    def test_unrelated_request_error_is_insufficient_evidence(self):
        class Client:
            def chat(self, body):
                raise RuntimeError("connection lost")

        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            dirs = SimpleNamespace(prompts=root / "prompts", answers=root / "answers", cancel=root / "cancel.json")
            server = SimpleNamespace(snapshot=SimpleNamespace(model_id="demo-ctx-32k", model_name="Demo", path=root / "config.json"),
                                     sampler=SimpleNamespace(samples=[], summary=lambda start: {"sample_count": 0}))
            rows = run_capacity_probe(Client(), server, dirs, runtime_paths().root, 1, "sample-run", 32768)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["status"], "failure")
            self.assertEqual(judge_capacity(rows, 32768)["status"], "insufficient")

    def test_cancellation_before_first_case_makes_no_request(self):
        class Client:
            def chat(self, body):
                raise AssertionError("cancelled probe must not send a request")

        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            dirs = SimpleNamespace(prompts=root / "prompts", answers=root / "answers", cancel=root / "cancel.json")
            server = SimpleNamespace(snapshot=SimpleNamespace(model_id="demo-ctx-32k", model_name="Demo", path=root / "config.json"),
                                     sampler=SimpleNamespace(samples=[], summary=lambda start: {"sample_count": 0}))
            with patch("launcher.benchmark.capacity.is_cancelled", return_value=True):
                rows = run_capacity_probe(Client(), server, dirs, runtime_paths().root, 1, "sample-run", 32768)
            self.assertEqual(rows, [])
