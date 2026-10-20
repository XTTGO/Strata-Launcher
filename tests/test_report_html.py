from __future__ import annotations

import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from launcher.benchmark import report
from launcher.benchmark.report import render_reports
from launcher.benchmark.share_image import render_share_svg


class HtmlReportDetails(unittest.TestCase):
    def test_parallel_only_preview_does_not_claim_performance_or_capacity(self):
        summary = {"manifest": {"request": {
            "preset_label": "并发专项", "stages": ["load"],
            "performance_cases": [["4k", 4014]], "load_input_lengths": ["4k", "32k"],
            "load_clients": [1, 2], "load_rounds": 2,
        }}, "models": {"m": {"model_name": "M", "context_tier": 262144,
                            "performance": {}, "load": []}}, "hardware": {}, "completion": {}}
        page = report._html_overview_preview(summary)
        svg = render_share_svg(summary)
        self.assertIn("并发输入</b> 4k / 32k", page)
        self.assertNotIn("输入上下文与生成速度</h2>", page)
        self.assertNotIn("上下文容量</h2>", page)
        self.assertNotIn("输入上下文与生成速度", svg)
        self.assertNotIn("上下文容量验证", svg)

    def test_preview_uses_selected_stages_and_current_request_values(self):
        summary = {
            "manifest": {"state": "completed", "request": {
                "preset_label": "日常速测", "rounds": 1,
                "stages": ["performance", "cache", "agent", "needle", "load"],
                "performance_cases": [["4k", 4014], ["128k", 128450]],
                "load_input_lengths": ["4k"], "load_clients": [1, 2],
                "load_rounds": 1, "load_max_tokens": 256,
                "agent_case_count": 7, "model_max_context": 262144,
                "uniform_config": True,
            }},
            "completion": {"state": "completed"}, "hardware": {}, "record_count": 1,
            "models": {"m": {
                "model_name": "M", "context_tier": 262144,
                "performance": {"performance-4k": {
                    "prompt_tps": {"median": 1000, "n": 1},
                    "decode_tps": {"median": 50, "n": 1},
                    "prefill_seconds": {"median": 4},
                    "vram_peak_mib": {"max": 12000},
                    "system_ram_peak_gib": {"max": 40},
                    "system_ram_peak_percent": {"max": 20},
                    "rss_peak_gib": {"max": 10},
                }},
                "cache": {"prefill_seconds": {"median": 2.5}, "reused_tokens": {"median": 20000}},
                "agent": {"passed": 6, "cases": 7},
                "needle": {"found": 3, "cases": 3},
                "load": [{"clients": 2, "input_length": "4k", "per_req_tps": 25.0,
                          "total_tps": 40.0, "serving_slots": 2, "output_overlap_seconds": 5.0,
                          "cached_tokens_max": 0, "errors": 0}],
                "stage_coverage": {"cache": {"state": "completed"}, "agent": {"state": "completed"},
                                   "needle": {"state": "completed"}, "load": {"state": "completed"}},
            }},
        }
        page = report._html_overview_preview(summary)
        full = report._html_report(summary)
        svg = render_share_svg(summary)
        self.assertIn("并发输入</b> 4k", page)
        self.assertIn("对话缓存", page)
        self.assertIn("内置 Agent 题集", page)
        self.assertIn("引擎槽数", page)
        self.assertIn("输出重叠", page)
        self.assertNotIn("约 800 词", page)
        self.assertNotIn("上下文容量</h2>", page)
        self.assertNotIn("稳定性</th>", page)
        self.assertNotIn("内置 7/9 道", full)
        self.assertIn("本次内置 7 道", full)
        self.assertNotIn("上下文容量验证", svg)

    def test_uniform_report_shows_effective_engine_slots(self):
        summary = {"manifest": {"request": {"uniform_config": True}}, "models": {
            "m": {"model_name": "M", "performance": {}, "load": [{"clients": 2, "serving_slots": 2,
                    "total_tps": 80.0, "per_req_tps": 40.0, "errors": 0}]}
        }, "hardware": {}, "completion": {}, "record_count": 0}
        page = report._html_report(summary)
        self.assertIn("对照条件默认生效", page)
        self.assertIn("引擎实测槽数", page)
        self.assertIn("<td>2</td><td>—</td><td>—</td><td>80.00", page)

    def test_uniform_html_lists_each_phase_snapshot_settings(self):
        summary = {"manifest": {"request": {"uniform_config": True,
                   "models": [{"model_id": "m", "model_name": "M"}]}},
                   "models": {}, "hardware": {}, "completion": {}, "record_count": 0}
        with tempfile.TemporaryDirectory() as folder:
            configs = Path(folder, "configs")
            configs.mkdir()
            for suffix, cache in (("", "0"), ("-cache", "6"), ("-load", "0")):
                (configs / f"m-round-1{suffix}.json").write_text(json.dumps({
                    "args": ["--prompt-cache", cache, "--pcie-frac", "0.20"], "parallel": 2,
                }), encoding="utf-8")
            page = report._html_report(summary, run_dir=Path(folder))
        self.assertIn("实际阶段参数", page)
        self.assertIn("--pcie-frac 0.20", page)
        self.assertIn("M / 缓存", page)

    def test_launcher_power_cap_is_visible_in_benchmark_reports(self):
        summary = {
            "hardware": {"gpu_power_limits": [{"uuid": "GPU-abc", "watts": 220.0, "launcher_target_watts": 220.0}]},
            "models": {}, "manifest": {}, "completion": {}, "record_count": 0,
        }
        self.assertIn("220 W", report._md_report(summary))
        self.assertIn("220 W", report._html_report(summary))
        self.assertIn("220 W", report._html_overview_preview(summary))
        self.assertIn("220 W", render_share_svg(summary))
    def test_overview_preview_shows_saved_concurrency_single_request_speed(self):
        summary = {
            "generated_at": "2026-10-10T05:40:04+00:00",
            "record_count": 124,
            "completion": {"state": "completed"},
            "manifest": {
                "state": "completed",
                "request": {
                    "preset": "full",
                    "rounds": 2,
                    "performance_cases": [["4k", 4014], ["256k", 256901]],
                    "load_clients": [1, 4],
                    "load_rounds": 3,
                    "load_max_tokens": 256,
                    "load_words": 800,
                    "max_concurrency": 4,
                    "model_max_context": "original",
                    "models": [{"model_id": "model-a", "config_hash": "abcdef0123456789"}],
                },
            },
            "hardware": {
                "platform": "Windows 11",
                "cpu": "AMD processor",
                "cpu_model": "AMD Ryzen Threadripper 3960X",
                "physical_cpu_count": 24,
                "logical_cpu_count": 48,
                "installed_ram_bytes": 256 * 1024**3,
                "strata_git_revision": "abcdef0123456789",
                "strata_engine_version": "0.1.41",
                "gpus": [{"name": "RTX 3090", "memory_total_mib": 24576, "driver_version": "610.62"}],
            },
            "models": {
                "model-a": {
                    "model_name": "Model A",
                    "effective_max_context": 262144,
                    "config_hash": "abcdef0123456789",
                    "performance": {
                        "4k": {
                            "decode_tps": {"median": 80.0, "min": 78.0, "max": 82.0},
                            "prompt_tps": {"median": 1000.0},
                            "ttft_seconds": {"median": 1.0},
                        }
                    },
                    "load": [{
                        "clients": 4, "total_tps": 90.0, "per_req_tps": 105.0,
                        "first_p50": 4.0, "first_p95": 8.0, "lat_p50": 7.0,
                        "lat_p95": 11.0, "errors": 0,
                    }],
                    "agent": {"passed": 8, "cases": 9},
                    "needle": {"found": 4, "cases": 4},
                    "stability": {"successes": 10, "requests": 10},
                    "memory_by_stage": {
                        "load": {
                            "system_ram_peak_gib": {"max": 80.0},
                            "rss_peak_gib": {"max": 50.0},
                            "vram_peak_mib": {"max": 23000.0},
                        }
                    },
                }
            },
        }

        self.assertTrue(hasattr(report, "_html_overview_preview"))
        page = report._html_overview_preview(summary)

        self.assertIn("截图概览", page)
        self.assertIn("Model A", page)
        self.assertIn("RTX 3090", page)
        self.assertIn("80.00 <small>tok/s</small>", page)
        self.assertIn("TTFT P50 / P95", page)
        self.assertIn("7.00 / 11.00", page)
        self.assertIn("单请求解码速度", page)
        self.assertIn("105.00", page)
        self.assertIn("总吞吐", page)
        self.assertIn("单请求解码速度不含首 token 等待", page)
        self.assertNotIn("历史记录没有逐请求", page)
        self.assertIn("256K", page)
        self.assertIn("每档 3 轮", page)
        self.assertIn("256 tokens", page)
        self.assertNotIn("约 800 词", page)
        self.assertIn("配置 abcdef01", page)
        self.assertIn("AMD Ryzen Threadripper 3960X", page)
        self.assertIn("导出分享 PNG", page)
        self.assertIn("ClipboardItem", page)
        self.assertIn("Strata</b> v0.1.41", page)
        self.assertIn("下载 PNG", page)
        self.assertIn("share-art", page)
        share_svg = render_share_svg(summary)
        self.assertIn(">105.00</text>", share_svg)
        svg_root = ET.fromstring(share_svg)
        self.assertEqual(svg_root.find("svg:rect", {"svg": "http://www.w3.org/2000/svg"}).attrib["fill"], "#eef2f7")
        cards = [
            node for node in svg_root.findall(".//{http://www.w3.org/2000/svg}rect")
            if node.attrib.get("width") == "1504"
            and node.attrib.get("fill") == "#ffffff"
            and node.attrib.get("rx") == "12"
        ]
        self.assertGreaterEqual(len(cards), 5, "SVG should follow the webpage's separate white-card layout")
        svg_text = [n.text or "" for n in svg_root.findall(".//{http://www.w3.org/2000/svg}text")]
        self.assertIn("Strata  v0.1.41", svg_text)
        self.assertNotIn("abcdef012345", " ".join(svg_text))
        self.assertIn("单请求 tok/s", share_svg)
        ns = {"svg": "http://www.w3.org/2000/svg"}
        main_speed = next(n for n in svg_root.findall(".//svg:text", ns) if n.text == "80.00 tok/s")
        speed_range = next(n for n in svg_root.findall(".//svg:text", ns) if n.text == "范围 78.00–82.00 tok/s")
        prompt_detail = next(n for n in svg_root.findall(".//svg:text", ns) if n.text and n.text.startswith("Prompt 1000.00"))
        self.assertGreater(int(main_speed.attrib["font-size"]), int(speed_range.attrib["font-size"]))
        self.assertGreater(int(main_speed.attrib["font-weight"]), int(prompt_detail.attrib["font-weight"]))
        self.assertGreater(int(speed_range.attrib["font-size"]), int(prompt_detail.attrib["font-size"]))
        version_summary = {
            "manifest": {"request": {}},
            "hardware": {"strata_engine_version": "0.1.41", "strata_git_revision": "abcdef0123456789"},
            "models": {},
            "record_count": 0,
        }
        markdown = report._md_report(version_summary)
        full_report = report._html_report(version_summary)
        self.assertIn("Strata 版本：0.1.41", markdown)
        self.assertIn("Strata commit：abcdef0123456789", markdown)
        self.assertIn("Strata 版本：<code>0.1.41</code>", full_report)
        ET.fromstring(share_svg)

    def test_render_reports_creates_overview_and_share_svg(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "run-manifest.json").write_text(
                json.dumps({"state": "completed", "request": {"preset": "standard", "models": []}}),
                encoding="utf-8",
            )
            (run_dir / "raw-results.jsonl").write_text("", encoding="utf-8")

            output = render_reports(run_dir)
            preview = Path(output["preview"])
            image = Path(output["share_svg"])
            report_page = Path(output["html"]).read_text(encoding="utf-8")
            self.assertTrue(preview.exists())
            self.assertTrue(image.exists())
            self.assertIn("report-preview.html", report_page)
            self.assertIn("<svg", image.read_text(encoding="utf-8"))

    def test_share_svg_keeps_long_model_label_out_of_performance_columns(self):
        model_name = "qwen3.8-flash-next-unsloth-ud-iq4_xs"
        summary = {
            "manifest": {
                "request": {
                    "performance_cases": [["4k", 4014]],
                    "models": [{"model_id": "model-long", "config_hash": "f4fdd7f9"}],
                }
            },
            "models": {
                "model-long": {
                    "model_name": model_name,
                    "config_hash": "f4fdd7f9",
                    "performance": {
                        "performance-4k": {
                            "decode_tps": {"median": 48.65, "min": 47.90, "max": 49.40, "n": 2},
                            "prompt_tps": {"median": 452.15},
                            "ttft_seconds": {"median": 9.13},
                        }
                    },
                    "load": [{
                        "clients": 4, "total_tps": 100.0, "per_req_tps": 80.0,
                        "first_p50": 2.0, "first_p95": 3.0, "lat_p50": 4.0,
                        "lat_p95": 5.0, "errors": 0,
                    }],
                    "memory_by_stage": {"load": {"system_ram_peak_gib": {"max": 32.0}}},
                }
            },
        }

        svg = ET.fromstring(render_share_svg(summary))
        ns = {"svg": "http://www.w3.org/2000/svg"}
        model_label = next(
            node for node in svg.findall(".//svg:text", ns)
            if node.attrib.get("x") == "66"
            and node.text
            and node.text.startswith(model_name)
            and 390 <= int(node.attrib["y"]) <= 450
        )
        config_labels = [
            node for node in svg.findall(".//svg:text", ns)
            if node.text == "配置 f4fdd7f9"
        ]
        speed_label = next(
            node for node in svg.findall(".//svg:text", ns)
            if node.text and node.text.startswith("48.65 tok/s")
        )
        clip_path = model_label.attrib.get("clip-path", "")
        self.assertTrue(clip_path.startswith("url(#"), "long model name must be clipped to its own column")
        clip_id = clip_path[5:-1]
        clip_rect = svg.find(f".//svg:clipPath[@id='{clip_id}']/svg:rect", ns)
        self.assertIsNotNone(clip_rect)
        self.assertEqual(len(config_labels), 1, "configuration hash must be on its own line")
        self.assertEqual(config_labels[0].attrib["x"], "66")
        self.assertGreaterEqual(int(speed_label.attrib["x"]), 400)
        clipped_tables = {
            node.attrib.get("clip-path", "").removeprefix("url(#").removesuffix(")")
            for node in svg.findall(".//svg:text", ns)
            if node.text == model_name and node.attrib.get("clip-path")
        }
        self.assertTrue({"performance-model-label-0", "load-model-label-0", "summary-model-label-0"} <= clipped_tables)

    def test_build_summary_resolves_effective_context_and_config_hash(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "configs").mkdir()
            (run_dir / "configs" / "model-a-round-1.json").write_text(
                json.dumps({"args": ["--max-context", "262144"]}), encoding="utf-8"
            )
            (run_dir / "run-manifest.json").write_text(
                json.dumps({
                    "state": "completed",
                    "request": {
                        "preset": "standard",
                        "models": [{"model_id": "model-a", "config_hash": "abcdef0123456789"}],
                    },
                }),
                encoding="utf-8",
            )
            (run_dir / "raw-results.jsonl").write_text(
                json.dumps({"model_id": "model-a", "model_name": "Model A", "stage": "startup", "status": "success"}) + "\n",
                encoding="utf-8",
            )

            summary = report.build_summary(run_dir)

        model = summary["models"]["model-a"]
        self.assertEqual(model["effective_max_context"], 262144)
        self.assertEqual(model["config_hash"], "abcdef0123456789")

    def test_requested_but_unrun_stage_is_reported_as_partial_not_zero_of_zero(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "run-manifest.json").write_text(
                json.dumps({
                    "state": "completed",
                    "request": {
                        "preset": "full",
                        "models": [{"model_id": "model-a", "model_name": "Model A"}],
                        "stages": ["performance", "stability"],
                        "rounds": 1,
                        "performance_cases": [["4k", 4014]],
                    },
                }),
                encoding="utf-8",
            )
            (run_dir / "raw-results.jsonl").write_text(
                json.dumps({
                    "model_id": "model-a",
                    "model_name": "Model A",
                    "stage": "performance",
                    "case_id": "performance-4k",
                    "status": "success",
                }) + "\n",
                encoding="utf-8",
            )

            output = render_reports(run_dir)
            summary = json.loads(Path(output["summary"]).read_text(encoding="utf-8"))
            page = Path(output["html"]).read_text(encoding="utf-8")
            markdown = Path(output["markdown"]).read_text(encoding="utf-8")

        self.assertEqual(summary["completion"]["state"], "partial")
        self.assertEqual(summary["manifest"]["state"], "completed")
        self.assertEqual(summary["models"]["model-a"]["stage_coverage"]["stability"]["state"], "not_run")
        self.assertEqual(summary["models"]["model-a"]["stage_coverage"]["stability"]["expected"], 10)
        for report in (page, markdown):
            self.assertIn("部分完成", report)
            self.assertIn("未执行", report)
            self.assertNotIn("0/0", report)

    def test_failed_requested_stage_makes_completion_partial(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "run-manifest.json").write_text(
                json.dumps({
                    "state": "completed",
                    "request": {
                        "models": [{"model_id": "model-a", "model_name": "Model A"}],
                        "stages": ["stability"],
                    },
                }),
                encoding="utf-8",
            )
            (run_dir / "raw-results.jsonl").write_text(
                json.dumps({
                    "model_id": "model-a",
                    "model_name": "Model A",
                    "stage": "stability",
                    "case_id": "stability-error",
                    "status": "failure",
                }) + "\n",
                encoding="utf-8",
            )

            output = render_reports(run_dir)
            summary = json.loads(Path(output["summary"]).read_text(encoding="utf-8"))

        self.assertEqual(summary["completion"]["state"], "partial")
        self.assertEqual(summary["models"]["model-a"]["stage_coverage"]["stability"]["state"], "failed")

    def test_run_is_complete_when_all_requested_stability_samples_exist(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "run-manifest.json").write_text(
                json.dumps({
                    "state": "running",
                    "request": {
                        "preset": "full",
                        "models": [{"model_id": "model-a", "model_name": "Model A"}],
                        "stages": ["stability"],
                        "rounds": 1,
                        "stability_requests": 10,
                    },
                }),
                encoding="utf-8",
            )
            rows = [
                {"model_id": "model-a", "stage": stage, "status": "success"}
                for stage in ("startup", "warmup")
            ]
            rows.extend(
                {"model_id": "model-a", "stage": "stability", "status": "success", "iteration": index}
                for index in range(1, 11)
            )
            (run_dir / "raw-results.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
            )

            output = render_reports(run_dir)
            summary = json.loads(Path(output["summary"]).read_text(encoding="utf-8"))

        self.assertEqual(summary["completion"]["state"], "completed")
        self.assertEqual(summary["manifest"]["state"], "running")
        self.assertEqual(summary["models"]["model-a"]["stage_coverage"]["stability"]["state"], "completed")

    def test_memory_report_summarizes_named_test_checkpoints(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "hardware.json").write_text(
                json.dumps({"installed_ram_bytes": 16 * 1024**3}), encoding="utf-8"
            )
            records = [
                {
                    "model_id": "model-a",
                    "model_name": "Model A",
                    "stage": "startup",
                    "case_id": "cold-start",
                    "status": "success",
                    "sample_count": 3,
                    "system_used_peak_bytes": 9 * 1024**3,
                    "rss_peak_bytes": 3 * 1024**3,
                    "gpu_memory_peak_mib": 11000,
                },
                {
                    "model_id": "model-a",
                    "model_name": "Model A",
                    "stage": "load",
                    "case_id": "clients-4",
                    "status": "success",
                    "sample_count": 5,
                    "system_used_peak_bytes": 12 * 1024**3,
                    "rss_peak_bytes": 4 * 1024**3,
                    "gpu_memory_peak_mib": 14000,
                },
            ]
            (run_dir / "raw-results.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in records), encoding="utf-8"
            )

            output = render_reports(run_dir)
            summary = json.loads(Path(output["summary"]).read_text(encoding="utf-8"))
            page = Path(output["html"]).read_text(encoding="utf-8")
            markdown = Path(output["markdown"]).read_text(encoding="utf-8")

        memory = summary["models"]["model-a"]["memory_by_stage"]
        self.assertEqual(memory["startup"]["system_ram_peak_gib"]["max"], 9.0)
        self.assertEqual(memory["load"]["system_ram_peak_percent"]["max"], 75.0)
        self.assertIn("关键阶段内存峰值", page)
        self.assertIn("模型启动", page)
        self.assertIn("并发负载（全部并发档）", page)
        self.assertNotIn("关键阶段内存峰值", markdown)

    def test_memory_metrics_are_unavailable_when_no_samples_were_taken(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "hardware.json").write_text(
                json.dumps({"installed_ram_bytes": 16 * 1024**3}), encoding="utf-8"
            )
            record = {
                "model_id": "model-a",
                "stage": "performance",
                "case_id": "4k",
                "status": "success",
                "sample_count": 0,
                "system_used_peak_bytes": 0,
                "rss_peak_bytes": 0,
                "gpu_memory_peak_mib": 0,
            }
            (run_dir / "raw-results.jsonl").write_text(
                json.dumps(record) + "\n", encoding="utf-8"
            )

            output = render_reports(run_dir)
            summary = json.loads(Path(output["summary"]).read_text(encoding="utf-8"))

        performance = summary["models"]["model-a"]["performance"]["4k"]
        for key in ("system_ram_peak_gib", "system_ram_peak_percent", "rss_peak_gib", "vram_peak_mib"):
            self.assertEqual(performance[key]["n"], 0)
            self.assertIsNone(performance[key]["max"])

    def test_reports_system_ram_peak_percent_and_strata_rss(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "run-manifest.json").write_text(
                json.dumps({"state": "completed", "request": {"preset": "standard"}}),
                encoding="utf-8",
            )
            (run_dir / "hardware.json").write_text(
                json.dumps({"installed_ram_bytes": 16 * 1024**3}), encoding="utf-8"
            )
            record = {
                "record_id": "perf-memory-1",
                "model_id": "model-a",
                "model_name": "Model A",
                "stage": "performance",
                "case_id": "4k",
                "round": 1,
                "status": "success",
                "prompt_tokens_per_second": 900.0,
                "decode_tokens_per_second": 80.0,
                "ttft_seconds": 1.3,
                "sample_count": 4,
                "system_used_peak_bytes": 8 * 1024**3,
                "rss_peak_bytes": 2 * 1024**3,
                "gpu_memory_peak_mib": 12000,
            }
            (run_dir / "raw-results.jsonl").write_text(
                json.dumps(record) + "\n", encoding="utf-8"
            )

            output = render_reports(run_dir)
            summary = json.loads(Path(output["summary"]).read_text(encoding="utf-8"))
            page = Path(output["html"]).read_text(encoding="utf-8")
            markdown = Path(output["markdown"]).read_text(encoding="utf-8")

        performance = summary["models"]["model-a"]["performance"]["4k"]
        self.assertEqual(performance["system_ram_peak_gib"]["max"], 8.0)
        self.assertEqual(performance["system_ram_peak_percent"]["max"], 50.0)
        self.assertEqual(performance["rss_peak_gib"]["max"], 2.0)
        for report in (page, markdown):
            self.assertIn("整机 RAM 峰值 GiB", report)
            self.assertIn("RAM 占比峰值", report)
            self.assertIn("Strata RSS 峰值 GiB", report)
            self.assertIn("50.00%", report)
            self.assertIn("2.00", report)
        self.assertIn("约 1 秒间隔采样", page)
        self.assertIn("约 1 秒间隔采样", markdown)

    def test_html_exposes_every_raw_result_field_and_stage_filters(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "run-manifest.json").write_text(
                json.dumps({
                    "state": "completed",
                    "request": {
                        "preset": "standard",
                        "rounds": 3,
                        "stages": ["needle", "load"],
                        "needle_lengths": ["32k"],
                    },
                }),
                encoding="utf-8",
            )
            rows = [
                {
                    "record_id": "perf-1",
                    "model_id": "model-a",
                    "model_name": "Model A",
                    "stage": "performance",
                    "case_id": "4k",
                    "round": 1,
                    "status": "success",
                    "prompt_tokens_per_second": 900.0,
                    "decode_tokens_per_second": 80.0,
                    "ttft_seconds": 1.3,
                    "gpu_memory_peak_mib": 12000,
                },
                {
                    "record_id": "needle-1",
                    "model_id": "model-a",
                    "model_name": "Model A",
                    "stage": "needle",
                    "case_id": "needle-32k-90",
                    "round": 1,
                    "status": "success",
                    "length": "32k",
                    "depth": 90,
                    "prompt_tokens": 31000,
                    "seconds": 12.5,
                    "found": True,
                    "word": "amber-falcon-123",
                    "answer": "amber-falcon-123 <verified>",
                },
                {
                    "record_id": "load-1",
                    "model_id": "model-a",
                    "model_name": "Model A",
                    "stage": "load",
                    "case_id": "clients-2",
                    "round": 1,
                    "status": "failure",
                    "clients": 2,
                    "total_tps": 45.2,
                    "per_req_tps": 22.6,
                    "first_p50": 1.2,
                    "first_p95": 1.8,
                    "lat_p50": 12.0,
                    "lat_p95": 14.0,
                    "errors": 1,
                    "error_detail": "request timeout",
                },
            ]
            with (run_dir / "raw-results.jsonl").open("w", encoding="utf-8") as stream:
                for row in rows:
                    stream.write(json.dumps(row) + "\n")

            output = render_reports(run_dir)
            page = Path(output["html"]).read_text(encoding="utf-8")

        self.assertIn("全部逐项结果", page)
        self.assertIn("Needle", page)
        self.assertIn("amber-falcon-123 &lt;verified&gt;", page)
        self.assertIn("request timeout", page)
        self.assertIn("31000", page)
        self.assertIn("45.2", page)
        self.assertIn("Prompt 处理速度", page)
        self.assertIn("Decode 生成速度", page)
        self.assertIn("900.00 tok/s", page)
        self.assertIn("data-stage=\"needle\"", page)
        self.assertIn("data-stage=\"load\"", page)

    def test_html_shows_recorded_run_parameters(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            run_dir = Path(folder)
            (run_dir / "run-manifest.json").write_text(
                json.dumps({
                    "state": "completed",
                    "request": {
                        "preset": "standard",
                        "rounds": 3,
                        "benchmark_port": 8188,
                        "stages": ["performance", "needle"],
                        "needle_lengths": ["32k", "128k"],
                        "load_clients": [1, 2],
                        "model_max_context": 524288,
                        "experimental_context_scaling": True,
                        "max_concurrency": 4,
                        "models": [{"model_name": "Model A", "config_hash": "abc123"}],
                    },
                }),
                encoding="utf-8",
            )
            render_reports(run_dir)
            page = (run_dir / "report.html").read_text(encoding="utf-8")

        self.assertIn("本次测试参数", page)
        self.assertIn("8188", page)
        self.assertIn("32k", page)
        self.assertIn("524288", page)
        self.assertIn("experimental_context_scaling", page)
        self.assertIn("4", page)
        self.assertIn("abc123", page)


if __name__ == "__main__":
    unittest.main()
