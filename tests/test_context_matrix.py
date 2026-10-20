from __future__ import annotations

import unittest
import json
import tempfile
import io
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path

from launcher.benchmark.models import ModelProfile, snapshot_profile
from launcher.benchmark.runner import build_context_variants, build_parser, command_estimate, eligible_context_cases, resolve_context_cases, resolve_context_tiers, run_benchmark


class ContextTierSelectionTests(unittest.TestCase):
    def test_no_selection_keeps_original_config(self):
        self.assertEqual(resolve_context_tiers([], False), ([None], []))

    def test_switch_off_rejects_multiple_checked_tiers(self):
        with self.assertRaisesRegex(ValueError, "开启多档"):
            resolve_context_tiers([524288, 131072], False)

    def test_switch_on_runs_all_checked_tiers_in_ascending_order(self):
        self.assertEqual(
            resolve_context_tiers([524288, 131072], True),
            ([131072, 524288], []),
        )

    def test_rejects_duplicate_and_unknown_tiers(self):
        with self.assertRaises(ValueError):
            resolve_context_tiers([131072, 131072], True)
        with self.assertRaises(ValueError):
            resolve_context_tiers([100000], True)

    def test_legacy_single_cap_still_works(self):
        self.assertEqual(resolve_context_tiers(None, False, 393216), ([393216], []))

    def test_empty_sweep_is_invalid(self):
        with self.assertRaises(ValueError):
            resolve_context_tiers([], True)
        with self.assertRaisesRegex(ValueError, "至少选择两个"):
            resolve_context_tiers([262144], True)

    def test_capacity_only_allows_no_regular_prompt_lengths(self):
        self.assertEqual(resolve_context_cases("standard", [], allow_empty=True), ([], []))
        with self.assertRaises(ValueError):
            resolve_context_cases("standard", [])

    def test_run_cli_accepts_multiple_tiers_and_sweep(self):
        args = build_parser().parse_args(
            ["run", "--context-tiers", "131072,524288", "--sweep-context-tiers"]
        )
        self.assertEqual(args.context_tiers, "131072,524288")
        self.assertTrue(args.sweep_context_tiers)

    def test_snapshots_for_two_tiers_do_not_collide(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            source = root / "strata-demo.json"
            source.write_text('{}', encoding="utf-8")
            raw = source.read_bytes()
            import hashlib
            profile = ModelProfile("strata-demo", "Demo", source, hashlib.sha256(raw).hexdigest(), raw,
                                   {"exe": "engine/strata.exe", "args": [], "model_name": "Demo"}, 8080)
            first = snapshot_profile(profile, root / "configs", 8188, 1,
                                     {"--max-context": "131072"}, variant_id="strata-demo-ctx-128k")
            second = snapshot_profile(profile, root / "configs", 8188, 1,
                                      {"--max-context": "524288"}, variant_id="strata-demo-ctx-512k")
            self.assertNotEqual(first.model_id, second.model_id)
            self.assertNotEqual(first.path, second.path)
            self.assertEqual(json.loads(first.path.read_text(encoding="utf-8"))["args"],
                             ["--max-context", "131072"])
            self.assertEqual(json.loads(second.path.read_text(encoding="utf-8"))["args"],
                             ["--max-context", "524288"])

    def test_lower_tier_marks_oversized_cases_not_applicable(self):
        performance, needle, skipped = eligible_context_cases(
            32768, [("4k", 4014), ("32k", 32112), ("128k", 128450)], ["4k", "32k", "128k"]
        )
        self.assertEqual(performance, [("4k", 4014), ("32k", 32112)])
        self.assertEqual(needle, ["4k", "32k"])
        self.assertEqual([(row["stage"], row["case_id"]) for row in skipped],
                         [("performance", "performance-128k"), ("needle", "needle-128k"), ("cache", "cache-32k")])

    def test_matrix_gives_each_model_tier_a_unique_identity(self):
        profile = ModelProfile("strata-demo", "Demo", Path("demo.json"), "abc", b"{}", {}, 8080)
        variants = build_context_variants([profile], [131072, 524288])
        self.assertEqual([item.profile.model_id for item in variants],
                         ["strata-demo-ctx-128k", "strata-demo-ctx-512k"])
        self.assertEqual([item.context_tier for item in variants], [131072, 524288])
        self.assertEqual([item.source_model_id for item in variants], ["strata-demo", "strata-demo"])

    def test_legacy_single_cap_preserves_old_result_identity(self):
        profile = ModelProfile("strata-demo", "Demo", Path("demo.json"), "abc", b"{}", {}, 8080)
        variants = build_context_variants([profile], [393216], legacy_single=True)
        self.assertEqual(variants[0].profile.model_id, "strata-demo")

    def test_estimate_counts_selected_tiers_and_phase_restarts(self):
        def estimate(*extra: str) -> dict:
            args = build_parser().parse_args(["estimate", "--model", "demo.json", *extra])
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(command_estimate(args), 0)
            return json.loads(output.getvalue())

        off = estimate("--context-tiers", "131072")
        on = estimate("--context-tiers", "131072,524288", "--sweep-context-tiers")
        self.assertEqual(off["model_sessions"], 1)
        self.assertEqual(on["model_sessions"], 2)
        self.assertEqual(on["effective_context_tiers"], [131072, 524288])
        self.assertEqual(off["planned_server_starts"], 3)
        self.assertEqual(on["planned_server_starts"], 6)

    def test_multi_tier_estimate_excludes_empty_load_phase_restart(self):
        args = build_parser().parse_args([
            "estimate", "--preset", "long", "--stages", "load", "--context-lengths", "128k",
            "--context-tiers", "32768,262144", "--sweep-context-tiers", "--model", "demo.json",
        ])
        output = io.StringIO()
        with redirect_stdout(output):
            command_estimate(args)
        result = json.loads(output.getvalue())
        self.assertEqual(result["model_sessions"], 2)
        self.assertEqual(result["planned_server_starts"], 3)
        self.assertEqual(result["load_bursts"], 2)

    def test_capacity_estimate_omits_unselected_daily_stages(self):
        args = build_parser().parse_args(["estimate", "--preset", "capacity", "--model", "demo.json"])
        output = io.StringIO()
        with redirect_stdout(output):
            command_estimate(args)
        result = json.loads(output.getvalue())
        self.assertEqual(result["rounds"], 1)
        self.assertEqual(result["model_max_context"], 262144)
        self.assertEqual(result["cache_requests"], 0)
        self.assertEqual(result["agent_requests"], 0)
        self.assertEqual(result["load_bursts"], 0)
        self.assertEqual(result["load_clients"], [])

    def test_parallel_estimate_counts_only_its_workload(self):
        args = build_parser().parse_args(["estimate", "--preset", "parallel", "--model", "demo.json", "--preset-policy"])
        output = io.StringIO()
        with redirect_stdout(output):
            command_estimate(args)
        result = json.loads(output.getvalue())
        self.assertEqual(result["load_input_lengths"], ["4k", "32k"])
        self.assertEqual(result["load_bursts"], 8)
        self.assertEqual(result["performance_requests"], 0)
        self.assertEqual(result["capacity_requests"], 0)

    def test_capacity_only_estimate_accepts_empty_input_selection(self):
        args = build_parser().parse_args(["estimate", "--preset", "capacity", "--stages", "capacity", "--context-lengths", ""])
        output = io.StringIO()
        with redirect_stdout(output):
            command_estimate(args)
        self.assertEqual(json.loads(output.getvalue())["capacity_requests"], 6)

    def test_run_creates_two_independent_tier_snapshots_and_reports(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            model = root / "strata-demo.json"
            model.write_text(json.dumps({"exe": "engine/strata.exe", "args": [], "model_name": "Demo", "port": 8080}), encoding="utf-8")
            starts = []

            def start(snapshot, *other):
                starts.append(snapshot)
                return SimpleNamespace(snapshot=snapshot, load_seconds=0.1,
                                       sampler=SimpleNamespace(samples=[], summary=lambda since: {"sample_count": 0}))

            def capacity(client, server, dirs, source, round_number, run_id, cap):
                return [{"model_id": server.snapshot.model_id, "model_name": "Demo", "stage": "capacity",
                         "case_id": f"capacity-{depth}-{repetition}", "round": 1, "depth": depth,
                         "repetition": repetition, "status": "success", "found": True,
                         "prompt_tokens": int(cap * 0.95), "finish_reason": "stop"}
                        for depth in (10, 50, 90) for repetition in (1, 2)]

            args = build_parser().parse_args([
                "run", "--root", str(root), "--model", str(model), "--report-root", str(root / "reports"),
                "--context-tiers", "32768,65536", "--sweep-context-tiers", "--stages", "capacity",
                "--context-lengths", "", "--rounds", "1",
            ])
            with patch("launcher.benchmark.runner._preflight"), \
                 patch("launcher.benchmark.runner.start_server", side_effect=start), \
                 patch("launcher.benchmark.runner.stop_server", return_value=SimpleNamespace(manual_cleanup_required=False)), \
                 patch("launcher.benchmark.runner.warm_up", return_value={"status": "success"}), \
                 patch("launcher.benchmark.runner.run_capacity_probe", side_effect=capacity), \
                 patch("launcher.benchmark.runner.verify_serving_slots", side_effect=lambda port, expected, context: expected), \
                 patch("launcher.benchmark.runner.collect_hardware", return_value={}):
                self.assertEqual(run_benchmark(args), 0)
            self.assertEqual([item.model_id for item in starts], ["strata-demo-ctx-32k", "strata-demo-ctx-64k"])
            run_dir = next((root / "reports").iterdir())
            summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
            self.assertEqual(summary["highest_verified_context"]["strata-demo"], 65536)
            self.assertEqual(len(summary["models"]), 2)

    def test_resource_failure_at_low_tier_prevents_higher_start(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            model = root / "strata-demo.json"
            model.write_text(json.dumps({"exe": "engine/strata.exe", "args": [], "model_name": "Demo", "port": 8080}), encoding="utf-8")
            starts = []

            def out_of_memory(snapshot, *other):
                starts.append(snapshot.model_id)
                raise RuntimeError("CUDA out of memory")

            args = build_parser().parse_args([
                "run", "--root", str(root), "--model", str(model), "--report-root", str(root / "reports"),
                "--context-tiers", "32768,65536", "--sweep-context-tiers", "--stages", "capacity",
                "--context-lengths", "", "--rounds", "1",
            ])
            with patch("launcher.benchmark.runner._preflight"), \
                 patch("launcher.benchmark.runner.start_server", side_effect=out_of_memory), \
                 patch("launcher.benchmark.runner.collect_hardware", return_value={}):
                self.assertEqual(run_benchmark(args), 1)
            self.assertEqual(starts, ["strata-demo-ctx-32k"])
            run_dir = next((root / "reports").iterdir())
            rows = [json.loads(line) for line in (run_dir / "raw-results.jsonl").read_text(encoding="utf-8").splitlines()]
            self.assertTrue(any(row.get("model_id") == "strata-demo-ctx-64k" and
                                row.get("status") == "skipped" for row in rows))

    def test_unclassified_startup_exit_also_prevents_higher_tier(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            model = root / "strata-demo.json"
            model.write_text(json.dumps({"exe": "engine/strata.exe", "args": [], "model_name": "Demo", "port": 8080}), encoding="utf-8")
            starts = []

            def exits(snapshot, *other):
                starts.append(snapshot.model_id)
                raise RuntimeError("Strata Server 启动退出，exit=1，日志见文件")

            args = build_parser().parse_args([
                "run", "--root", str(root), "--model", str(model), "--report-root", str(root / "reports"),
                "--context-tiers", "32768,65536", "--sweep-context-tiers", "--stages", "capacity",
                "--context-lengths", "", "--rounds", "1",
            ])
            with patch("launcher.benchmark.runner._preflight"), \
                 patch("launcher.benchmark.runner.start_server", side_effect=exits), \
                 patch("launcher.benchmark.runner.collect_hardware", return_value={}):
                self.assertEqual(run_benchmark(args), 1)
            self.assertEqual(starts, ["strata-demo-ctx-32k"])

    def test_default_run_does_not_add_matrix_metadata(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            model = root / "strata-demo.json"
            model.write_text(json.dumps({"exe": "engine/strata.exe", "args": ["--max-context", "262144"], "model_name": "Demo", "port": 8080}), encoding="utf-8")
            args = build_parser().parse_args([
                "run", "--root", str(root), "--model", str(model), "--report-root", str(root / "reports"),
                "--stages", "agent", "--rounds", "1",
            ])
            with patch("launcher.benchmark.runner._preflight"), \
                 patch("launcher.benchmark.runner.start_server", return_value=SimpleNamespace(
                     snapshot=SimpleNamespace(path=root / "snapshot.json"), load_seconds=0.1,
                     sampler=SimpleNamespace(samples=[], summary=lambda since: {"sample_count": 0}))), \
                 patch("launcher.benchmark.runner.stop_server", return_value=SimpleNamespace(manual_cleanup_required=False)), \
                 patch("launcher.benchmark.runner.warm_up", return_value={"status": "success"}), \
                 patch("launcher.benchmark.runner.verify_serving_slots", side_effect=lambda port, expected, context: expected), \
                 patch("launcher.benchmark.runner.load_cases", return_value=[]), \
                 patch("launcher.benchmark.runner.collect_hardware", return_value={}):
                self.assertEqual(run_benchmark(args), 1)
            run_dir = next((root / "reports").iterdir())
            request = json.loads((run_dir / "run-manifest.json").read_text(encoding="utf-8"))["request"]
            self.assertNotIn("context_tier", request["models"][0])
            self.assertNotIn("selected_context_tiers", request)
            records = [json.loads(line) for line in (run_dir / "raw-results.jsonl").read_text(encoding="utf-8").splitlines()]
            self.assertTrue(records)
            self.assertTrue(all("context_tier" not in row for row in records))
