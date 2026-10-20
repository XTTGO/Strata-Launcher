from __future__ import annotations

import unittest
import tempfile
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from launcher.benchmark.workloads import _timing_fields, PerformanceCase, StrataClient, run_performance, build_measured_prompt


class TimingFieldsTests(unittest.TestCase):
    def test_token_counter_uses_same_text_and_disables_thinking(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *_): return None
            def read(self): return b'{"input_tokens":4014}'
        with patch("launcher.benchmark.workloads.urllib.request.urlopen", return_value=Response()) as request:
            self.assertEqual(StrataClient(8188).count_tokens("source"), 4014)
        self.assertTrue(request.call_args.args[0].full_url.endswith("/v1/messages/count_tokens"))
        body = json.loads(request.call_args.args[0].data)
        self.assertEqual(body["messages"][0]["content"], "source")
        self.assertEqual(body["thinking"], {"type": "disabled"})

    def test_prompt_fits_current_model_tokenizer_before_inference(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            (root / "README.md").write_text("benchmark source text " * 100, encoding="utf-8")
            dirs = SimpleNamespace(prompts=root / "prompts")
            dirs.prompts.mkdir()
            client = SimpleNamespace(count_tokens=lambda text: len(text) // 4 + 8)
            prompt, path = build_measured_prompt(root, dirs, client, 4014, "4k", "model-a")
            self.assertLessEqual(abs(client.count_tokens(prompt) - 4014), 4014 * 0.005)
            self.assertEqual(path.read_text(encoding="utf-8"), prompt)
            self.assertIn("model-a", path.name)

    def test_short_prompt_calibration_includes_request_nonce(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            (root / "README.md").write_text("benchmark source text " * 100, encoding="utf-8")
            dirs = SimpleNamespace(prompts=root / "prompts")
            dirs.prompts.mkdir()
            client = SimpleNamespace(count_tokens=lambda text: len(text) // 4 + 8)
            prefix = "[strata-benchmark unique request marker]\n"
            prompt, _ = build_measured_prompt(root, dirs, client, 1024, "1k", "model-a", prefix=prefix)
            self.assertLessEqual(abs(client.count_tokens(prefix + prompt) - 1024), 1024 * 0.005)

    def test_current_strata_counts_total_reused_and_fresh_prompt_tokens(self):
        response = {
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 6,
                "total_tokens": 106,
                "prompt_tokens_details": {"cached_tokens": 76},
            },
            "timings": {
                "prompt_n": 24,
                "cache_n": 76,
                "prompt_ms": 120.0,
                "prompt_per_second": 200.0,
                "predicted_n": 6,
                "predicted_ms": 200.0,
                "predicted_per_second": 30.0,
            },
        }

        fields = _timing_fields(response, wall_s=0.4)

        self.assertEqual(fields["prompt_tokens"], 100)
        self.assertEqual(fields["reused_prompt_tokens"], 76)
        self.assertEqual(fields["new_prompt_tokens"], 24)
        self.assertEqual(fields["prefill_seconds"], 0.12)
        self.assertNotIn("ttft_seconds", fields)

    def test_usage_details_remain_fallback_when_engine_timings_are_absent(self):
        response = {
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": 20,
                "completion_tokens": 2,
                "total_tokens": 22,
                "prompt_tokens_details": {"cached_tokens": 7},
            },
        }

        fields = _timing_fields(response, wall_s=0.2)

        self.assertEqual(fields["prompt_tokens"], 20)
        self.assertEqual(fields["reused_prompt_tokens"], 7)
        self.assertEqual(fields["new_prompt_tokens"], 13)

    def test_cold_performance_rejects_reused_prefix(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            root = Path(folder)
            (root / "README.md").write_text("benchmark source text " * 100, encoding="utf-8")
            dirs = SimpleNamespace(prompts=root / "prompts", answers=root / "answers")
            dirs.prompts.mkdir()
            server = SimpleNamespace(snapshot=SimpleNamespace(model_id="m", model_name="M", path=root / "m.json",
                                                              config={"args": ["--max-context", "32768"]}),
                                     sampler=SimpleNamespace(samples=[], summary=lambda _: {}))
            response = {"choices": [{"message": {"content": "ok"}}],
                        "usage": {"prompt_tokens": 102, "completion_tokens": 2},
                        "timings": {"prompt_n": 86, "cache_n": 16, "prompt_ms": 100,
                                    "prompt_per_second": 860, "predicted_per_second": 20}}
            client = SimpleNamespace(get_json=lambda *_: {"max_context": 32768},
                                     count_tokens=lambda text: 100,
                                     chat=lambda *_: (response, 0.4))
            row = run_performance(client, server, dirs, root, PerformanceCase("performance-test", "test", 100), 1, 1, "run")
            self.assertEqual(row["status"], "failure")
            self.assertIn("16", row["error"])


if __name__ == "__main__":
    unittest.main()
