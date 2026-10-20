from __future__ import annotations

import unittest
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

from launcher.benchmark import runner
from launcher.benchmark.models import ModelProfile, snapshot_profile
from launcher.benchmark.processes import TelemetrySampler
from launcher.benchmark.workloads import build_prompt


class ContextSelection(unittest.TestCase):
    def test_daily_presets_bound_long_input_and_cold_concurrency(self):
        self.assertEqual([label for label, _ in runner.PRESETS["full"]["performance"]], ["1k", "4k", "32k"])
        self.assertEqual(runner.PRESETS["full"]["context_tier"], 262144)
        self.assertEqual(runner.PRESETS["full"]["rounds"], 3)
        self.assertEqual(runner.PRESETS["full"]["load_lengths"], ["4k"])
        self.assertNotIn("capacity", runner.PRESETS["full"]["stages"])
        self.assertEqual([label for label, _ in runner.PRESETS["long"]["performance"]], ["32k", "128k"])
        self.assertNotIn("load", runner.PRESETS["long"]["stages"])
        self.assertEqual(runner.PRESETS["parallel"]["stages"], ["load"])
        self.assertEqual(runner.PRESETS["parallel"]["load_lengths"], ["4k", "32k"])
        self.assertEqual([label for label, _ in runner.PRESETS["capacity"]["performance"]], ["256k"])
        self.assertNotIn("load", runner.PRESETS["capacity"]["stages"])
        self.assertEqual(runner.PRESETS["capacity"]["rounds"], 1)
        self.assertEqual(runner.PRESETS["capacity"]["load_rounds"], 1)

    def test_daily_full_load_uses_only_its_short_input_policy(self):
        performance, needle = runner.resolve_context_cases("full", ["1k", "4k", "32k"], preset_policy=True)
        self.assertEqual(needle, ["4k", "32k"])
        self.assertEqual(runner.load_context_cases(performance, "full"), [("4k", 4014)])

    def test_hardware_report_includes_friendly_cpu_model_when_available(self):
        paths = SimpleNamespace(root=Path.cwd())
        with (
            patch.object(runner, "_friendly_cpu_name", return_value="AMD Ryzen Threadripper 3960X"),
            patch.object(runner, "_git_revision", return_value="abcdef012345"),
            patch.object(runner, "_engine_version", return_value="0.1.41"),
            patch.object(runner, "query_nvidia", return_value=[]),
            patch.object(runner, "_file_fact", return_value={}),
        ):
            hardware = runner.collect_hardware(paths)

        self.assertEqual(hardware["cpu_model"], "AMD Ryzen Threadripper 3960X")
        self.assertEqual(hardware["strata_engine_version"], "0.1.41")
        self.assertNotIn("gpu_power_limits", hardware)

    def test_benchmark_records_measured_power_when_launcher_cap_is_active(self):
        with TemporaryDirectory(dir=Path(__file__).parent / ".tmp") as folder:
            launcher_dir = Path(folder)
            (launcher_dir / "data").mkdir()
            (launcher_dir / "data" / "gpu-power-restore.json").write_text(
                json.dumps({"records": [{"uuid": "GPU-abc", "original": 259, "last_applied": 220}]}),
                encoding="utf-8",
            )
            paths = SimpleNamespace(root=Path.cwd(), launcher=launcher_dir)
            with (
                patch.object(runner, "query_nvidia", return_value=[]),
                patch.object(runner, "_query_nvidia_power_limits", return_value=[{"uuid": "GPU-abc", "watts": 220.0}]),
                patch.object(runner, "_file_fact", return_value={}),
            ):
                hardware = runner.collect_hardware(paths)
            self.assertEqual(hardware["gpu_power_limits"], [{"uuid": "GPU-abc", "watts": 220.0, "launcher_target_watts": 220.0}])

    def test_engine_version_comes_from_engine_build_metadata(self):
        with TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            (root / "engine").mkdir()
            (root / "engine" / "BUILD.json").write_text(
                '{"version":"0.1.41","source":"release"}', encoding="utf-8"
            )

            self.assertEqual(runner._engine_version(root), "0.1.41")

    def test_selected_lengths_include_only_checked_cases(self):
        self.assertTrue(hasattr(runner, "resolve_context_cases"))
        performance, needle = runner.resolve_context_cases("standard", ["32k", "256k"])
        self.assertEqual(performance, [("32k", 32112), ("256k", 256901)])
        self.assertEqual(needle, ["32k", "256k"])

    def test_4k_is_selectable_as_an_input_length(self):
        performance, needle = runner.resolve_context_cases("standard", ["4k", "32k"])
        self.assertEqual(performance, [("4k", 4014), ("32k", 32112)])
        self.assertEqual(needle, ["4k", "32k"])

    def test_missing_selection_preserves_existing_preset_defaults(self):
        performance, needle = runner.resolve_context_cases("standard", None)
        self.assertEqual(performance, runner.PRESETS["standard"]["performance"])
        self.assertEqual(needle, runner.PRESETS["standard"]["needle_lengths"])
        self.assertIn("4k", [label for label, _ in performance])

    def test_384k_is_a_model_context_cap_with_yarn_scaling(self):
        self.assertIn(393216, runner.MODEL_CONTEXT_CHOICES)
        overrides = runner.resolve_model_context_overrides(393216)
        self.assertEqual(overrides["--max-context"], "393216")
        self.assertEqual(overrides["--rope-scaling"], "yarn")
        self.assertEqual(overrides["--rope-scale"], "1.5")
        self.assertEqual(overrides["--yarn-orig-ctx"], "262144")

    def test_384k_input_is_not_a_supported_prompt_length(self):
        with self.assertRaisesRegex(ValueError, "未知上下文长度"):
            runner.resolve_context_cases("standard", ["384k"])

    def test_default_run_uses_fast_daily_preset_rounds(self):
        args = runner.build_parser().parse_args(["run"])
        runner.apply_preset_defaults(args)
        self.assertEqual(args.rounds, 1)
        self.assertEqual(runner.resolve_load_clients("full", None), [1, 2])

    def test_explicit_source_context_is_not_overridden_by_preset(self):
        args = runner.build_parser().parse_args(["estimate", "--source-context"])
        runner.apply_preset_defaults(args)
        self.assertIsNone(args.max_context)
        self.assertEqual(runner._selected_tiers_from_args(args)[0], [None])
        with self.assertRaisesRegex(ValueError, "不能与"):
            conflicting = runner.build_parser().parse_args(["estimate", "--source-context", "--max-context", "262144"])
            runner._selected_tiers_from_args(conflicting)

    def test_old_stress_cli_preset_requires_explicit_new_choice(self):
        args = runner.build_parser().parse_args(["estimate", "--preset", "stress"])
        with self.assertRaisesRegex(ValueError, "已拆分"):
            runner.apply_preset_defaults(args)

    def test_empty_stage_workload_is_rejected_before_launch(self):
        with self.assertRaisesRegex(ValueError, "召回.*输入"):
            runner.validate_stage_workloads(["needle"], [("1k", 1024)], [], [("1k", 1024)], [262144])
        with self.assertRaisesRegex(ValueError, "并发.*输入"):
            runner.validate_stage_workloads(["load"], [("1k", 1024)], [], [], [262144])
        with self.assertRaisesRegex(ValueError, "缓存需要"):
            runner.validate_stage_workloads(["cache"], [], [], [], [32768])

    def test_unknown_or_empty_selected_lengths_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "上下文长度"):
            runner.resolve_context_cases("standard", ["999k"])
        with self.assertRaisesRegex(ValueError, "至少选择"):
            runner.resolve_context_cases("standard", [])

    def test_run_command_accepts_context_lengths(self):
        args = runner.build_parser().parse_args(
            ["run", "--context-lengths", "32k,128k"]
        )
        self.assertEqual(args.context_lengths, "32k,128k")

    def test_model_context_override_adds_yarn_for_experimental_512k(self):
        overrides = runner.resolve_model_context_overrides(524288)
        self.assertEqual(overrides["--max-context"], "524288")
        self.assertEqual(overrides["--rope-scaling"], "yarn")
        self.assertEqual(overrides["--rope-scale"], "2")
        self.assertEqual(overrides["--yarn-orig-ctx"], "262144")

    def test_model_context_override_leaves_native_rope_settings_alone(self):
        self.assertEqual(runner.resolve_model_context_overrides(None), {})
        self.assertEqual(runner.resolve_model_context_overrides(262144), {"--max-context": "262144"})

    def test_model_context_limit_must_fit_selected_prompts_and_outputs(self):
        cases, needle = runner.resolve_context_cases("standard", ["32k"])
        runner.validate_context_capacity(32768, cases, needle)
        too_long, too_long_needle = runner.resolve_context_cases("standard", ["128k"])
        with self.assertRaisesRegex(ValueError, "至少需要"):
            runner.validate_context_capacity(32768, too_long, too_long_needle)

    def test_max_concurrency_runs_each_client_count_from_one_to_limit(self):
        self.assertEqual(runner.resolve_load_clients("standard", None), [1, 2])
        self.assertEqual(runner.resolve_load_clients("full", None), [1, 2])
        self.assertEqual(runner.resolve_load_clients("standard", 3), [1, 2, 3])
        with self.assertRaisesRegex(ValueError, "并发数"):
            runner.resolve_load_clients("standard", 5)

    def test_manually_enabled_stability_runs_requests_under_standard_preset(self):
        self.assertEqual(runner.resolve_stability_requests("standard", ["performance"]), 0)
        self.assertEqual(runner.resolve_stability_requests("standard", ["stability"]), 10)
        self.assertEqual(runner.resolve_stability_requests("full", ["stability"]), 10)

    def test_standard_stability_selection_reaches_workload_and_manifest(self):
        with TemporaryDirectory(dir=Path.cwd()) as folder:
            root = Path(folder)
            source = root / "strata-demo.json"
            source.write_text(json.dumps({"exe": "engine/strata.exe", "args": ["--native", "demo.gguf", "--max-context", "262144"],
                                          "model_name": "Demo", "port": 8080}), encoding="utf-8")
            args = runner.build_parser().parse_args([
                "run", "--root", str(root), "--model", str(source), "--report-root", str(root / "reports"),
                "--preset", "standard", "--stages", "stability", "--context-lengths", "",
                "--rounds", "1",
            ])

            def start(snapshot, *other):
                return SimpleNamespace(snapshot=snapshot, load_seconds=0.1,
                                       sampler=SimpleNamespace(samples=[], summary=lambda since: {"sample_count": 0}))

            with patch.object(runner, "_preflight"), \
                 patch.object(runner, "start_server", side_effect=start), \
                 patch.object(runner, "stop_server", return_value=SimpleNamespace(manual_cleanup_required=False)), \
                 patch.object(runner, "warm_up", return_value={"status": "success"}), \
                 patch.object(runner, "verify_serving_slots", side_effect=lambda port, expected, context: expected), \
                 patch.object(runner, "run_stability", return_value=[]) as stability, \
                 patch.object(runner, "collect_hardware", return_value={}):
                runner.run_benchmark(args)

            self.assertEqual(stability.call_args.args[-1], 10)
            run_dir = next((root / "reports").iterdir())
            manifest = json.loads((run_dir / "run-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["request"]["stability_requests"], 10)

    def test_source_context_keeps_original_cap_in_benchmark_snapshot(self):
        with TemporaryDirectory(dir=Path.cwd()) as folder:
            root = Path(folder)
            source = root / "strata-demo.json"
            original = {"exe": "engine/strata.exe", "args": ["--native", "demo.gguf", "--max-context", "131072"],
                        "model_name": "Demo", "port": 8080}
            source.write_text(json.dumps(original), encoding="utf-8")
            args = runner.build_parser().parse_args([
                "run", "--root", str(root), "--model", str(source), "--report-root", str(root / "reports"),
                "--preset", "standard", "--source-context", "--stages", "stability", "--context-lengths", "",
            ])
            snapshots = []

            def start(snapshot, *other):
                snapshots.append(snapshot)
                return SimpleNamespace(snapshot=snapshot, load_seconds=0.1,
                                       sampler=SimpleNamespace(samples=[], summary=lambda since: {"sample_count": 0}))

            with patch.object(runner, "_preflight"), \
                 patch.object(runner, "start_server", side_effect=start), \
                 patch.object(runner, "stop_server", return_value=SimpleNamespace(manual_cleanup_required=False)), \
                 patch.object(runner, "warm_up", return_value={"status": "success"}), \
                 patch.object(runner, "verify_serving_slots", side_effect=lambda port, expected, context: expected), \
                 patch.object(runner, "run_stability", return_value=[]), \
                 patch.object(runner, "collect_hardware", return_value={}):
                runner.run_benchmark(args)

            self.assertEqual(snapshots[0].config["args"][snapshots[0].config["args"].index("--max-context") + 1], "131072")
            self.assertEqual(json.loads((next((root / "reports").iterdir()) / "run-manifest.json").read_text(encoding="utf-8"))["request"]["model_max_context"], "原配置")
            self.assertEqual(json.loads(source.read_text(encoding="utf-8")), original)

    def test_source_context_rejects_different_rope_scaling(self):
        with TemporaryDirectory(dir=Path.cwd()) as folder:
            root = Path(folder)
            sources = []
            for name, scaling in (("a", "1.5"), ("b", "2")):
                path = root / f"strata-{name}.json"
                path.write_text(json.dumps({"exe": "engine/strata.exe", "args": ["--native", f"{name}.gguf", "--max-context", "524288",
                                   "--rope-scaling", "yarn", "--rope-scale", scaling, "--yarn-orig-ctx", "262144"],
                                      "model_name": name, "port": 8080}), encoding="utf-8")
                sources.append(path)
            args = runner.build_parser().parse_args([
                "run", "--root", str(root), "--model", str(sources[0]), "--model", str(sources[1]),
                "--report-root", str(root / "reports"), "--source-context", "--stages", "stability", "--context-lengths", "",
            ])
            with patch.object(runner, "_preflight"), self.assertRaisesRegex(RuntimeError, "缩放参数不同"):
                runner.run_benchmark(args)

    def test_stage_wrapper_attaches_only_samples_taken_during_the_stage(self):
        sampler = TelemetrySampler(pid=1)
        sampler.samples.append({"rss_bytes": 100, "system_used_bytes": 200, "gpus": []})
        server = SimpleNamespace(sampler=sampler)

        def run_stage():
            sampler.samples.append({"rss_bytes": 300, "system_used_bytes": 400, "gpus": []})
            return [{"stage": "load", "case_id": "clients-4"}]

        records = runner._with_stage_telemetry(server, run_stage)

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["sample_count"], 1)
        self.assertEqual(records[0]["rss_peak_bytes"], 300)
        self.assertEqual(records[0]["system_used_peak_bytes"], 400)

    def test_runner_accepts_model_context_and_concurrency_overrides(self):
        args = runner.build_parser().parse_args(
            ["run", "--max-context", "524288", "--max-concurrency", "4"]
        )
        self.assertEqual(args.max_context, 524288)
        self.assertEqual(args.max_concurrency, 4)

    def test_512k_overrides_only_the_benchmark_config_snapshot(self):
        with TemporaryDirectory(dir=Path.cwd()) as temp:
            root = Path(temp)
            source = root / "strata-test.json"
            original = json.dumps({"model_name": "test", "exe": "strata.exe", "args": ["--max-context", "262144"]}).encode()
            source.write_bytes(original)
            profile = ModelProfile("test", "test", source, hashlib.sha256(original).hexdigest(), original, json.loads(original), 8080)
            snapshot = snapshot_profile(
                profile,
                root / "snapshots",
                8188,
                1,
                runner.resolve_model_context_overrides(524288),
            )
            self.assertEqual(source.read_bytes(), original)
            args = snapshot.config["args"]
            self.assertEqual(args[args.index("--max-context") + 1], "524288")
            self.assertEqual(args[args.index("--rope-scaling") + 1], "yarn")
            self.assertEqual(args[args.index("--rope-scale") + 1], "2")

    def test_each_supported_selected_prompt_length_gets_its_own_file(self):
        with TemporaryDirectory(dir=Path.cwd()) as temp:
            root = Path(temp)
            (root / "README.md").write_text("Strata long context benchmark source. " * 100, encoding="utf-8")
            prompts = root / "prompts"
            prompts.mkdir()
            for label, target_tokens in (("4k", 4014), ("32k", 32112), ("128k", 128450), ("256k", 256901)):
                with self.subTest(label=label):
                    prompt, path = build_prompt(
                        root, SimpleNamespace(prompts=prompts), target_tokens, label
                    )
                    self.assertEqual(path.name, f"prompt-{label}.txt")
                    self.assertTrue(path.exists())
                    self.assertTrue(prompt.endswith("请用三句话总结上面的资料。"))
            self.assertGreater((prompts / "prompt-256k.txt").stat().st_size, 800_000)


if __name__ == "__main__":
    unittest.main()
