from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from launcher.benchmark.models import ModelProfile, discover_profiles, snapshot_profile
from launcher.benchmark.runner import build_parser, run_benchmark, verify_serving_slots
from launcher.benchmark.uniform import normalize_uniform_config, validate_uniform_compatibility


def _profile(path: Path, name: str, config: dict) -> ModelProfile:
    raw = json.dumps(config).encode("utf-8")
    path.write_bytes(raw)
    return ModelProfile(name, name, path, hashlib.sha256(raw).hexdigest(), raw, config, 8080)


class UniformConfigTests(unittest.TestCase):
    def test_new_strata_user_args_cannot_override_benchmark_conditions(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            config = {
                "exe": "engine/strata.exe", "model_name": "Demo", "port": 8080,
                "args": ["--native", "model.gguf", "--max-context", "32768",
                         "--vram-reserve-mib", "2048", "--vision"],
                "user_args": ["--max-context", "131072", "--vram-reserve-mib", "0",
                              "--expert-profile-save", "profile.bin", "--spec", "4"],
                "args_written": ["--native", "model.gguf", "--max-context", "32768"],
                "vision": {"gpu": True},
            }
            profile = _profile(root / "strata-demo.json", "demo", config)
            discovered = discover_profiles(root)[0]
            self.assertEqual(discovered.config["args"][discovered.config["args"].index("--max-context") + 1], "131072")
            snapshot = snapshot_profile(profile, root / "configs", 8188, 1,
                                        {"--max-context": "262144"}, uniform_phase="solo")
            args = snapshot.config["args"]
            self.assertEqual(args[args.index("--max-context") + 1], "262144")
            self.assertEqual(args[args.index("--vram-reserve-mib") + 1], "3072")
            self.assertEqual(args[args.index("--spec") + 1], "4")
            self.assertNotIn("--vision", args)
            self.assertNotIn("--expert-profile-save", args)
            self.assertNotIn("user_args", snapshot.config)
            self.assertNotIn("args_written", snapshot.config)
            self.assertEqual(json.loads(profile.config_path.read_text()), config)

    def test_cli_uses_controlled_snapshots_by_default(self):
        self.assertTrue(build_parser().parse_args(["run"]).uniform_config)

    def test_normalizes_tuning_without_changing_model_files(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            config = {
                "exe": "engine/strata.exe", "model_name": "Demo", "port": 8080,
                "args": ["--pack", "pack-a", "--native", "model-a.gguf", "--max-context", "524288",
                         "--rope-scaling", "yarn", "--rope-scale", "2", "--yarn-orig-ctx", "262144",
                         "--pcie-frac", "0.35", "--spec-min-p", "0.70", "--pool-workers", "15",
                         "--resident-budget-gib", "55", "--vision", "--vram-reserve-mib", "3806",
                         "--adapt-every", "1", "--adapt-swaps", "80", "--adapt-decay", "0.97"],
                "vision": {"gpu": True}, "parallel": 4,
                "env": {"STRATA_ROUTE_TAIL_SKIP": "0"},
                "sampling": {"temperature": 0.8},
            }
            profile = _profile(root / "model.json", "demo", config)
            original = profile.config_path.read_bytes()
            solo = snapshot_profile(profile, root / "configs", 8188, 1,
                                    {"--max-context": "262144"}, uniform_phase="solo", uniform_slots=2)
            cache = snapshot_profile(profile, root / "configs", 8188, 1,
                                     {"--max-context": "262144"}, uniform_phase="cache", uniform_slots=2)
            load = snapshot_profile(profile, root / "configs", 8188, 1,
                                    {"--max-context": "262144"}, uniform_phase="load", uniform_slots=2)
            self.assertEqual(profile.config_path.read_bytes(), original)
            self.assertEqual(len({solo.path, cache.path, load.path}), 3)
            self.assertEqual({solo.model_id, cache.model_id, load.model_id}, {"demo"})
            for item in (solo, cache, load):
                args = item.config["args"]
                self.assertEqual(args[args.index("--max-context") + 1], "262144")
                for removed in ("--rope-scaling", "--vision"):
                    self.assertNotIn(removed, args)
                self.assertNotIn("vision", item.config)
                self.assertEqual(item.config["env"]["STRATA_ROUTE_TAIL_SKIP"], "0")
                self.assertEqual(args[args.index("--pcie-frac") + 1], "0.35")
                self.assertEqual(args[args.index("--spec-min-p") + 1], "0.70")
                self.assertEqual(args[args.index("--pool-workers") + 1], "15")
                self.assertEqual(args[args.index("--resident-budget-gib") + 1], "55")
                self.assertEqual(args[args.index("--adapt-swaps") + 1], "80")
                self.assertEqual(args[args.index("--vram-reserve-mib") + 1], "3072")
                self.assertEqual(item.config["sampling"]["temperature"], 0.8)
            self.assertEqual(solo.config["parallel"], 1)
            self.assertEqual(cache.config["parallel"], 1)
            self.assertEqual(load.config["parallel"], 2)
            self.assertEqual(solo.config["args"][solo.config["args"].index("--prompt-cache") + 1], "0")
            self.assertEqual(cache.config["args"][cache.config["args"].index("--prompt-cache") + 1], "6")
            self.assertEqual(load.config["args"][load.config["args"].index("--prompt-cache") + 1], "0")

    def test_audit_preserves_unrecognized_model_tuning_without_treating_it_as_test_control(self):
        base = {"exe": "engine/strata.exe", "args": ["--native", "a.gguf"], "model_name": "A"}
        first = normalize_uniform_config(base, phase="solo", slots=2)
        second = normalize_uniform_config({**base, "args": ["--native", "b.gguf", "--mystery-tuning", "9"]},
                                          phase="solo", slots=2)
        validate_uniform_compatibility([first, second])
        self.assertIn("--mystery-tuning", second["args"])

    def test_no_selected_context_keeps_source_yarn_settings(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            config = {"args": ["--native", "model.gguf", "--max-context", "524288",
                               "--rope-scaling", "yarn", "--rope-scale", "2",
                               "--yarn-orig-ctx", "262144"]}
            profile = _profile(root / "model.json", "demo", config)
            snapshot = snapshot_profile(profile, root / "configs", 8188, 1,
                                        uniform_phase="solo", uniform_slots=1)
            self.assertEqual(snapshot.config["args"][snapshot.config["args"].index("--rope-scaling") + 1], "yarn")

    def test_model_specific_mtp_path_is_allowed_but_missing_mtp_is_not(self):
        base = {"exe": "engine/strata.exe", "args": ["--native", "a.gguf", "--mtp", "a-mtp"],
                "model_name": "A"}
        first = normalize_uniform_config(base, phase="solo", slots=2)
        second = normalize_uniform_config({**base, "args": ["--native", "b.gguf", "--mtp", "b-mtp"]},
                                          phase="solo", slots=2)
        validate_uniform_compatibility([first, second])
        missing = normalize_uniform_config({**base, "args": ["--native", "b.gguf"]},
                                           phase="solo", slots=2)
        validate_uniform_compatibility([first, missing])

    def test_different_model_tuning_is_allowed_but_resource_controls_match(self):
        base = {"args": ["--native", "a.gguf", "--pcie-frac", "0.20", "--pool-workers", "4",
                         "--vram-reserve-mib", "512"], "model_name": "A"}
        other = {"args": ["--native", "b.gguf", "--pcie-frac", "0.35", "--pool-workers", "15",
                          "--vram-reserve-mib", "4096"], "model_name": "B"}
        first = normalize_uniform_config(base, phase="solo", slots=2)
        second = normalize_uniform_config(other, phase="solo", slots=2)
        validate_uniform_compatibility([first, second])
        self.assertEqual(first["args"][first["args"].index("--pcie-frac") + 1], "0.20")
        self.assertEqual(second["args"][second["args"].index("--pcie-frac") + 1], "0.35")
        for config in (first, second):
            args = config["args"]
            self.assertEqual(args[args.index("--vram-reserve-mib") + 1], "3072")
            self.assertEqual(args[args.index("--kv-resident") + 1], "32768")

    def test_load_rejects_engine_slot_downgrade(self):
        with patch("launcher.benchmark.runner.read_server_status", return_value={"concurrency": {"serving": 1}}):
            with self.assertRaisesRegex(RuntimeError, "实际只有 1"):
                verify_serving_slots(8188, 2)
        with patch("launcher.benchmark.runner.read_server_status", return_value={"concurrency": {"serving": 2}}):
            self.assertEqual(verify_serving_slots(8188, 2), 2)

    def test_runtime_check_rejects_context_downgrade_and_vision_reenable(self):
        status = {"concurrency": {"serving": 1}, "context": {"max_positions": 131072},
                  "vision": {"enabled": False}}
        with patch("launcher.benchmark.runner.read_server_status", return_value=status):
            with self.assertRaisesRegex(RuntimeError, "上下文"):
                verify_serving_slots(8188, 1, 262144)
        status["context"]["max_positions"] = 262144
        status["vision"]["enabled"] = True
        with patch("launcher.benchmark.runner.read_server_status", return_value=status):
            with self.assertRaisesRegex(RuntimeError, "视觉"):
                verify_serving_slots(8188, 1, 262144)

    def test_runner_uses_separate_solo_cache_and_load_snapshots(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            source = root / "strata-demo.json"
            source.write_text(json.dumps({"exe": "engine/strata.exe", "args": ["--native", "demo.gguf"],
                                          "model_name": "Demo", "port": 8080}), encoding="utf-8")
            original = source.read_bytes()
            starts = []

            def start(snapshot, *other):
                starts.append(snapshot)
                return SimpleNamespace(snapshot=snapshot, load_seconds=0.1,
                                       sampler=SimpleNamespace(samples=[], summary=lambda since: {"sample_count": 0}))

            args = build_parser().parse_args([
                "run", "--root", str(root), "--model", str(source), "--report-root", str(root / "reports"),
                "--context-tiers", "65536", "--stages", "cache,load", "--context-lengths", "4k",
                "--max-concurrency", "2", "--rounds", "1", "--uniform-config",
            ])
            with patch("launcher.benchmark.runner._preflight"), \
                 patch("launcher.benchmark.runner.start_server", side_effect=start), \
                 patch("launcher.benchmark.runner.stop_server", return_value=SimpleNamespace(manual_cleanup_required=False)), \
                 patch("launcher.benchmark.runner.warm_up", return_value={"status": "success"}), \
                 patch("launcher.benchmark.runner.run_cache_sequence", return_value=[]), \
                 patch("launcher.benchmark.runner.run_load", return_value=[]) as load_tool, \
                 patch("launcher.benchmark.runner.verify_serving_slots", side_effect=lambda port, expected, context: expected), \
                 patch("launcher.benchmark.runner.collect_hardware", return_value={}):
                run_benchmark(args)
            self.assertEqual(load_tool.call_args.kwargs["rounds"], 1)
            self.assertEqual(load_tool.call_args.kwargs["context_cases"], [("4k", 4014)])
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual([item.config["parallel"] for item in starts], [1, 1, 2])
            self.assertEqual([item.config["args"][item.config["args"].index("--prompt-cache") + 1]
                              for item in starts], ["0", "6", "0"])
            self.assertEqual(len({item.path for item in starts}), 3)
            run_dir = next((root / "reports").iterdir())
            manifest = json.loads((run_dir / "run-manifest.json").read_text(encoding="utf-8"))
            self.assertTrue(manifest["request"]["uniform_config"])
            self.assertEqual(manifest["request"]["model_max_context"], 65536)

    def test_slot_downgrade_records_failure_without_running_load_tool(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            source = root / "strata-demo.json"
            source.write_text(json.dumps({"exe": "engine/strata.exe", "args": ["--native", "demo.gguf"],
                                          "model_name": "Demo", "port": 8080}), encoding="utf-8")

            def start(snapshot, *other):
                return SimpleNamespace(snapshot=snapshot, load_seconds=0.1,
                                       sampler=SimpleNamespace(samples=[], summary=lambda since: {"sample_count": 0}))

            args = build_parser().parse_args([
                "run", "--root", str(root), "--model", str(source), "--report-root", str(root / "reports"),
                "--context-tiers", "65536", "--stages", "load", "--context-lengths", "4k",
                "--max-concurrency", "2", "--rounds", "1", "--uniform-config",
            ])
            def slots(port, expected, context):
                if expected == 2:
                    raise RuntimeError("实际只有 1 槽")
                return expected

            with patch("launcher.benchmark.runner._preflight"), \
                 patch("launcher.benchmark.runner.start_server", side_effect=start), \
                 patch("launcher.benchmark.runner.stop_server", return_value=SimpleNamespace(manual_cleanup_required=False)), \
                 patch("launcher.benchmark.runner.warm_up", return_value={"status": "success"}), \
                 patch("launcher.benchmark.runner.verify_serving_slots", side_effect=slots), \
                 patch("launcher.benchmark.runner.run_load") as load_tool, \
                 patch("launcher.benchmark.runner.collect_hardware", return_value={}):
                self.assertEqual(run_benchmark(args), 1)
                load_tool.assert_not_called()
            run_dir = next((root / "reports").iterdir())
            rows = [json.loads(line) for line in (run_dir / "raw-results.jsonl").read_text(encoding="utf-8").splitlines()]
            self.assertTrue(any(row.get("stage") == "load" and row.get("status") == "failure" and
                                "实际只有 1 槽" in row["error"]["message"] for row in rows))


if __name__ == "__main__":
    unittest.main()
