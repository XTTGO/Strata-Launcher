import json
import tempfile
import unittest
from pathlib import Path

from launcher.benchmark.report import _md_report, render_reports


class MarkdownReportTests(unittest.TestCase):
    def test_short_share_sentence_and_selected_performance_only(self):
        summary = {
            "manifest": {"state": "completed", "request": {"stages": ["performance"], "rounds": 1,
                "uniform_config": True, "performance_cases": [["4k", 4014]], "models": [
                    {"model_id": "a", "model_name": "Model A", "source_model_id": "strata-a", "context_tier": 524288}]}},
            "completion": {"state": "completed"}, "hardware": {"gpus": [{"name": "NVIDIA GeForce RTX 3090"}]},
            "models": {"a": {"model_name": "Model A · 512K", "context_tier": 524288,
                "performance": {"performance-4k": {"prompt_tps": {"n": 1, "median": 100},
                    "decode_tps": {"n": 1, "median": 20}, "prefill_seconds": {"median": 3.2},
                    "vram_peak_mib": {"max": 22000}, "system_ram_peak_gib": {"max": 32}}}}},
        }
        records = [{"model_id": "a", "stage": "performance", "case_id": "performance-4k",
                    "status": "success", "prompt_tokens": 4076, "record_id": "private-record-id"}]
        result = _md_report(summary, records)
        sentence = result.split("## 一句话分享\n\n", 1)[1].split("\n\n", 1)[0]
        self.assertLessEqual(len(sentence), 180)
        self.assertIn("4K", sentence)
        self.assertIn("20.00 tok/s", sentence)
        self.assertIn("n=1", sentence)
        self.assertIn("4,076", result)
        self.assertIn("引擎预填充中位数", result)
        self.assertNotIn("TTFT 中位数", result)
        self.assertNotIn("上下文容量", result)
        self.assertNotIn("## 并发", result)
        self.assertNotIn("private-record-id", result)
        self.assertNotIn("全部逐项结果", result)

    def test_no_valid_result_does_not_invent_a_speed(self):
        summary = {"manifest": {"state": "completed", "request": {"stages": ["performance"],
                   "models": [{"model_id": "a"}]}}, "completion": {"state": "partial"},
                   "hardware": {}, "models": {"a": {"model_name": "A", "performance": {},
                   "stage_coverage": {"performance": {"state": "not_run", "successes": 0,
                   "expected": 1, "failures": 0, "skipped": 0}}}}}
        result = _md_report(summary)
        sentence = result.split("## 一句话分享\n\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("无可比较的有效结果", result)
        self.assertIn("部分完成", result)
        self.assertIn("未执行", result)
        self.assertNotIn("tok/s", sentence)

    def test_agent_transport_success_does_not_count_as_assertion_pass(self):
        summary = {"manifest": {"state": "completed", "request": {"stages": ["agent"], "models": []}},
                   "hardware": {}, "record_count": 1, "models": {"m": {"model_name": "M",
                   "agent": {"cases": 1, "passed": 0}, "successes": 1, "failures": 0,
                   "stage_coverage": {"agent": {"state": "completed", "successes": 1, "expected": 1,
                                                "failures": 0, "skipped": 0}}}}}
        result = _md_report(summary)
        self.assertIn("Agent 内置题集", result)
        self.assertIn("0/1", result)
        self.assertIn("仅表示内置题集断言通过率", result)

    def test_capacity_only_has_no_empty_performance_or_paths(self):
        summary = {"manifest": {"state": "completed", "request": {"stages": ["capacity"],
                   "models": [{"model_id": "m", "config_path": "C:/private/strata-m.json",
                               "config_hash": "abc123", "context_tier": 32768}]}},
                   "completion": {"state": "completed"}, "hardware": {},
                   "models": {"m": {"model_name": "M", "context_tier": 32768,
                   "capacity": {"cases": 1, "hits": 1, "status": "verified",
                                "actual_prompt_tokens_min": 30000, "actual_prompt_tokens_max": 30000}}}}
        result = _md_report(summary)
        self.assertIn("上下文容量", result)
        self.assertIn("30,000", result)
        self.assertNotIn("## 基础性能", result)
        self.assertNotIn("abc123", result)
        self.assertNotIn("C:/private", result)

    def test_load_only_share_uses_real_two_client_total(self):
        summary = {"manifest": {"state": "completed", "request": {"stages": ["load"],
                   "models": [{"model_id": "a", "source_model_id": "strata-a"}]}},
                   "completion": {"state": "completed"}, "hardware": {},
                   "models": {"a": {"model_name": "A", "load": [{"clients": 2,
                   "input_length": "4k", "prompt_tokens_min": 4091, "prompt_tokens_max": 4102,
                   "serving_slots": 2, "total_tps": 80.5, "per_req_tps": 40.25,
                   "first_p50": 1.2, "output_overlap_seconds": 2.0,
                   "cached_tokens_max": 0, "errors": 0}]}}}
        result = _md_report(summary)
        sentence = result.split("## 一句话分享\n\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("2 客户端总吞吐", sentence)
        self.assertIn("80.50 tok/s", sentence)
        self.assertIn("4,091–4,102", result)
        self.assertIn("输出重叠", result)
        self.assertNotIn("## 基础性能", result)

    def test_normal_export_and_rerender_follow_same_markdown_contract(self):
        summary = {"manifest": {"state": "completed", "request": {"preset": "standard",
                   "rounds": 1, "stages": ["performance"], "models": [{"model_id": "m",
                   "source_model_id": "strata-m", "context_tier": 524288}]}},
                   "completion": {"state": "completed"}, "hardware": {}, "record_count": 1,
                   "models": {"m": {"model_name": "M · 512K", "context_tier": 524288,
                   "performance": {"performance-4k": {"prompt_tps": {"n": 1, "median": 100.0},
                   "decode_tps": {"n": 1, "median": 25.0},
                   "prefill_seconds": {"median": 1.0}, "vram_peak_mib": {"max": None},
                   "system_ram_peak_gib": {"max": None}, "system_ram_peak_percent": {"max": None},
                   "rss_peak_gib": {"max": None}}}}}}
        record = {"model_id": "m", "stage": "performance", "case_id": "performance-4k",
                  "status": "success", "prompt_tokens": 4076, "record_id": "do-not-expose"}
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            (root / "raw-results.jsonl").write_text(json.dumps(record) + "\n", encoding="utf-8")
            first = render_reports(root, summary)
            md_before = Path(first["markdown"]).read_text(encoding="utf-8")
            second = render_reports(root, summary)
            md_after = Path(second["markdown"]).read_text(encoding="utf-8")
            self.assertEqual(md_before, md_after)
            self.assertTrue(Path(second["html"]).exists())
            self.assertTrue(Path(second["summary"]).exists())
        self.assertIn("## 一句话分享", md_before)
        self.assertIn("25.00 tok/s（n=1）", md_before)
        self.assertIn("4,076", md_before)
        self.assertNotIn("## 上下文容量", md_before)
        self.assertNotIn("do-not-expose", md_before)


if __name__ == "__main__":
    unittest.main()
