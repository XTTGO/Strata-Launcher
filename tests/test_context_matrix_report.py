from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from launcher.benchmark.report import _html_overview_preview, _md_report, assess_completion, build_summary
from launcher.benchmark.share_image import render_share_svg


class ContextMatrixReportTests(unittest.TestCase):
    def test_inapplicable_long_cases_do_not_make_lower_tier_incomplete(self):
        request = {"rounds": 1, "stages": ["performance", "needle", "cache"],
                   "performance_cases": [["4k", 4014], ["32k", 32112], ["128k", 128450]],
                   "needle_lengths": ["4k", "32k", "128k"],
                   "models": [{"model_id": "demo-ctx-32k", "model_name": "Demo", "context_tier": 32768}]}
        rows = [{"model_id": "demo-ctx-32k", "stage": "startup", "status": "success"},
                {"model_id": "demo-ctx-32k", "stage": "warmup", "status": "success"}]
        rows += [{"model_id": "demo-ctx-32k", "stage": "performance", "status": "success"} for _ in range(2)]
        rows += [{"model_id": "demo-ctx-32k", "stage": "performance", "status": "skipped", "reason": "档位不适用：输入与输出预留超过模型上限"}]
        rows += [{"model_id": "demo-ctx-32k", "stage": "needle", "status": "success"} for _ in range(6)]
        rows += [{"model_id": "demo-ctx-32k", "stage": "needle", "status": "skipped", "reason": "档位不适用：输入与输出预留超过模型上限"}]
        rows += [{"model_id": "demo-ctx-32k", "stage": "cache", "status": "skipped", "reason": "档位不适用：多轮缓存测试需要超过 32K 的空间"}]
        result = assess_completion(request, rows)
        self.assertEqual(result["state"], "completed")
        self.assertEqual(result["models"]["demo-ctx-32k"]["stages"]["needle"]["expected"], 7)

    def test_separate_tiers_and_highest_verified_are_reported(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            models = [
                {"model_id": "demo-ctx-128k", "source_model_id": "demo", "model_name": "Demo", "context_tier": 131072},
                {"model_id": "demo-ctx-512k", "source_model_id": "demo", "model_name": "Demo", "context_tier": 524288},
            ]
            request = {"preset": "standard", "rounds": 1, "stages": ["capacity"], "models": models,
                       "selected_context_tiers": [131072, 524288], "effective_context_tiers": [131072, 524288],
                       "performance_cases": [], "needle_lengths": [], "load_clients": []}
            (root / "run-manifest.json").write_text(json.dumps({"state": "completed", "request": request}), encoding="utf-8")
            rows = []
            for model_id, cap, tokens in (("demo-ctx-128k", 131072, 125000), ("demo-ctx-512k", 524288, 500000)):
                for depth in (10, 50, 90):
                    for repetition in (1, 2):
                        rows.append({"model_id": model_id, "model_name": "Demo", "stage": "capacity",
                                     "case_id": f"capacity-{depth}-{repetition}", "round": 1,
                                     "depth": depth, "repetition": repetition, "status": "success",
                                     "found": not (cap == 524288 and depth == 90 and repetition == 2),
                                     "prompt_tokens": tokens, "finish_reason": "stop", "context_tier": cap})
            (root / "raw-results.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            summary = build_summary(root)
            self.assertEqual(summary["models"]["demo-ctx-128k"]["capacity"]["status"], "verified")
            self.assertEqual(summary["models"]["demo-ctx-512k"]["capacity"]["status"], "failed")
            self.assertEqual(summary["highest_verified_context"]["demo"], 131072)
            self.assertEqual(summary["completion"]["state"], "partial")
            self.assertIn("上下文容量", _md_report(summary))
            self.assertIn("125,000", _html_overview_preview(summary))
            self.assertIn("128K", render_share_svg(summary))
            self.assertIn("容量验证", render_share_svg(summary))

    def test_old_report_has_no_invented_capacity_result(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            (root / "run-manifest.json").write_text(json.dumps({"request": {"models": []}}), encoding="utf-8")
            (root / "raw-results.jsonl").write_text("", encoding="utf-8")
            summary = build_summary(root)
            self.assertEqual(summary.get("highest_verified_context"), {})
