from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from launcher.benchmark import official_tools
from launcher.benchmark.report import assess_completion, build_summary
from launcher.benchmark.workloads import CacheCase, PerformanceCase, run_cache_sequence, run_performance, run_stability
from tools import needle_bench


def _server(root: Path) -> SimpleNamespace:
    return SimpleNamespace(
        snapshot=SimpleNamespace(model_id="model-a", model_name="Model A", path=root / "model.json",
                                 port=8188, config={"args": ["--max-context", "65536"]}),
        sampler=SimpleNamespace(samples=[], summary=lambda _: {}),
    )


class MeasurementGuardsTests(unittest.TestCase):
    def test_needle_calibrates_with_serving_tokenizer_before_request(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            out = Path(folder) / "needle.json"
            counted = []

            def count(_url, _key, prompt, _timeout):
                counted.append(len(prompt))
                return len(prompt) // 4

            def ask(_url, _key, prompt, _timeout):
                secret = re.search(r"secret code word for this text is: ([^.]*)", prompt).group(1)
                return secret, len(prompt) // 4, 0.1

            args = ["needle_bench.py", "--lengths", "4k", "--depths", "10", "--calibrate-length",
                    "--out", str(out)]
            with patch.object(sys, "argv", args), \
                 patch.object(needle_bench, "haystack", side_effect=lambda size: "A" * size), \
                 patch.object(needle_bench, "count_prompt_tokens", side_effect=count, create=True), \
                 patch.object(needle_bench, "ask", side_effect=ask), \
                 patch.object(needle_bench.urllib.request, "urlopen", side_effect=OSError):
                self.assertEqual(needle_bench.main(), 0)
            self.assertTrue(counted)
            row = json.loads(out.read_text(encoding="utf-8"))[0]
            self.assertTrue(4014 * 0.95 <= row["prompt_tokens"] <= 4014 * 1.05)

    def test_cache_rejects_wrong_input_length_and_missing_reuse(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            (root / "README.md").write_text("benchmark source " * 100, encoding="utf-8")
            dirs = SimpleNamespace(prompts=root / "prompts", answers=root / "answers", cancel=root / "cancel")
            dirs.prompts.mkdir()
            prompt_path = dirs.prompts / "cache.txt"
            prompt_path.write_text("source", encoding="utf-8")
            calls = 0

            def chat(_body):
                nonlocal calls
                calls += 1
                return ({"choices": [{"message": {"content": "answer"}, "finish_reason": "stop"}],
                         "usage": {"prompt_tokens": 1000 if calls == 1 else 33000, "completion_tokens": 5},
                         "timings": {"cache_n": 0, "prompt_n": 1000,
                                     "prompt_per_second": 100, "predicted_per_second": 20}}, 0.2)

            client = SimpleNamespace(chat=chat)
            with patch("launcher.benchmark.workloads.build_measured_prompt", return_value=("source", prompt_path)) as fit:
                rows = run_cache_sequence(client, _server(root), dirs, root, CacheCase(), 1, "run")
            fit.assert_called_once()
            self.assertEqual(len(rows), 3)
            self.assertEqual(rows[0]["status"], "failure")
            self.assertEqual(rows[1]["status"], "failure")
            self.assertIn("缓存", rows[1]["error"])

    def test_cache_allows_small_warmup_prefix_but_requires_large_followup_hit(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            dirs = SimpleNamespace(prompts=root / "prompts", answers=root / "answers", cancel=root / "cancel")
            dirs.prompts.mkdir()
            calls = 0

            def chat(_body):
                nonlocal calls
                calls += 1
                reused = 32 if calls == 1 else 14000
                return ({"choices": [{"message": {"content": "answer"}, "finish_reason": "stop"}],
                         "usage": {"prompt_tokens": 32768 + calls * 10, "completion_tokens": 5},
                         "timings": {"cache_n": reused, "prompt_n": 32768 + calls * 10 - reused}}, 0.2)

            with patch("launcher.benchmark.workloads.build_measured_prompt",
                       return_value=("source", dirs.prompts / "cache.txt")):
                rows = run_cache_sequence(SimpleNamespace(chat=chat), _server(root), dirs, root, CacheCase(), 1, "run")
            self.assertEqual([row["status"] for row in rows], ["success"] * 3)

    def test_performance_rejects_missing_decode_speed(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            dirs = SimpleNamespace(prompts=root / "prompts", answers=root / "answers")
            dirs.prompts.mkdir()
            response = {"choices": [{"message": {"content": "answer"}, "finish_reason": "stop"}],
                        "usage": {"prompt_tokens": 100, "completion_tokens": 5},
                        "timings": {"cache_n": 0, "prompt_n": 100, "prompt_per_second": 100}}
            client = SimpleNamespace(get_json=lambda *_: {"max_context": 65536},
                                     chat=lambda *_: (response, 0.2))
            with patch("launcher.benchmark.workloads.build_measured_prompt", return_value=("source", root / "p.txt")):
                row = run_performance(client, _server(root), dirs, root,
                                      PerformanceCase("performance-test", "test", 100), 1, 1, "run")
            self.assertEqual(row["status"], "failure")
            self.assertIn("速度", row["error"])

    def test_stability_rejects_empty_success_response(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            dirs = SimpleNamespace(cancel=root / "cancel")
            client = SimpleNamespace(chat=lambda *_: ({}, 0.1))
            rows = run_stability(client, _server(root), dirs, 1, "run", count=1)
            self.assertEqual(rows[0]["status"], "failure")

    def test_needle_requires_real_input_length(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            dirs = SimpleNamespace(root=root, logs=root, cancel=root / "cancel")
            server = _server(root)
            paths = SimpleNamespace(root=root, python=Path("python"))
            commands = []

            def fake_tool(command, *_args, **_kwargs):
                commands.append(command)
                out = Path(command[command.index("--out") + 1])
                out.write_text(json.dumps([{"length": "4k", "depth": 10, "found": True,
                                            "prompt_tokens": 1200}]), encoding="utf-8")
                return 0

            with patch.object(official_tools, "_run_owned_tool", side_effect=fake_tool):
                row = official_tools.run_needle(server, paths, dirs, 1, "run", ["4k"], [10])[0]
            self.assertIn("--calibrate-length", commands[0])
            self.assertEqual(row["status"], "failure")
            self.assertIn("输入", row["error"])

    def test_needle_keeps_numeric_length_supported_by_tool(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            dirs = SimpleNamespace(root=root, logs=root, cancel=root / "cancel")
            paths = SimpleNamespace(root=root, python=Path("python"))

            def fake_tool(command, *_args, **_kwargs):
                Path(command[command.index("--out") + 1]).write_text(
                    json.dumps([{"length": "4096", "depth": 10, "found": True,
                                 "prompt_tokens": 4014}]), encoding="utf-8")
                return 0

            with patch.object(official_tools, "_run_owned_tool", side_effect=fake_tool):
                row = official_tools.run_needle(_server(root), paths, dirs, 1, "run", ["4096"], [10])[0]
            self.assertEqual(row["status"], "success")

    def test_needle_report_counts_failed_attempts_in_denominator(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            request = {"models": [{"model_id": "model-a"}], "stages": ["needle"],
                       "needle_lengths": ["4k"], "rounds": 1}
            (root / "run-manifest.json").write_text(json.dumps({"state": "completed", "request": request}), encoding="utf-8")
            rows = [{"model_id": "model-a", "stage": "needle", "status": "success", "found": True},
                    {"model_id": "model-a", "stage": "needle", "status": "failure", "error": "HTTP 500"}]
            (root / "raw-results.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            needle = build_summary(root)["models"]["model-a"]["needle"]
            self.assertEqual(needle["cases"], 3)
            self.assertEqual(needle["found"], 1)
            self.assertAlmostEqual(needle["recall_rate"], 1 / 3)

    def test_insufficient_capacity_is_partial_not_unrun(self):
        request = {"models": [{"model_id": "model-a", "context_tier": 32768}],
                   "stages": ["capacity"], "rounds": 1}
        rows = [{"model_id": "model-a", "stage": "capacity", "status": "insufficient",
                 "depth": depth, "repetition": rep, "prompt_tokens": 1000, "found": False}
                for depth in (10, 50, 90) for rep in (1, 2)]
        state = assess_completion(request, rows)["models"]["model-a"]["stages"]["capacity"]["state"]
        self.assertEqual(state, "partial")


if __name__ == "__main__":
    unittest.main()
