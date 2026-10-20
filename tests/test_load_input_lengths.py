from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

from launcher.benchmark import official_tools, runner
from launcher.benchmark.report import assess_completion, _expected_stage_records
from tools import serve_load


class LoadInputLengths(unittest.TestCase):
    def test_load_prompt_uses_selected_length_and_keeps_request_nonce(self):
        with TemporaryDirectory(dir=Path.cwd()) as folder:
            base = Path(folder) / "prompt.txt"
            base.write_text("source material " * 1000, encoding="utf-8")
            text = serve_load.prompt_for(1, 800, " run-2-0", base.read_text(encoding="utf-8"))
            self.assertTrue(text.startswith("["))
            self.assertIn("source material ", text)
            self.assertIn("[request 1 run-2-0]", text)
            self.assertIn("mechanical watch", text)

    def test_load_runner_sends_every_selected_length_to_tool_and_records_usage(self):
        with TemporaryDirectory(dir=Path.cwd()) as folder:
            root = Path(folder)
            (root / "README.md").write_text("Benchmark source. " * 100, encoding="utf-8")
            (root / "tools").mkdir()
            (root / "tools" / "serve_load.py").write_text("", encoding="utf-8")
            dirs = SimpleNamespace(root=root, prompts=root / "prompts", logs=root / "logs")
            dirs.prompts.mkdir()
            dirs.logs.mkdir()
            server = SimpleNamespace(snapshot=SimpleNamespace(model_id="test", model_name="Test", path=root / "config.json", port=8188))
            paths = SimpleNamespace(root=root, python=Path("python"))
            commands = []

            def fake_tool(command, _cwd, _log, _dirs, timeout):
                commands.append(command)
                out = Path(command[command.index("--json") + 1])
                tokens = 33000 if "32k" in out.name else 4150
                out.write_text(json.dumps([{"clients": 2, "errors": 0, "prompt_tokens_min": tokens,
                                            "prompt_tokens_max": tokens + 10, "prompt_token_samples": 6,
                                            "cached_tokens_max": 0, "cached_token_samples": 6,
                                            "output_overlap_seconds": 0.5}]), encoding="utf-8")
                return 0

            with patch.object(official_tools, "build_measured_prompt", return_value=("source text", root / "source.txt")), \
                 patch.object(official_tools, "_run_owned_tool", side_effect=fake_tool):
                rows = official_tools.run_load(server, paths, dirs, 1, "run", [2],
                                               context_cases=[("4k", 4014), ("32k", 32112)])
            self.assertEqual([row["case_id"] for row in rows], ["load-4k-clients-2", "load-32k-clients-2"])
            self.assertEqual([row["input_length"] for row in rows], ["4k", "32k"])
            self.assertTrue(all("--prompt-file" in command for command in commands))
            self.assertEqual(len(commands), 2)
            self.assertEqual(rows[0]["prompt_tokens_min"], 4150)
            self.assertTrue(all(row["status"] == "success" for row in rows))

    def test_load_selection_requires_a_length_and_is_included_in_estimate(self):
        with self.assertRaisesRegex(ValueError, "至少选择"):
            runner.resolve_context_cases("standard", [], allow_empty=False)
        self.assertEqual(runner.load_context_cases([("4k", 4014)]), [("4k", 4014)])

    def test_streamed_load_request_records_server_prompt_usage(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return None

            def __iter__(self):
                return iter([
                    b'data: {"choices":[{"delta":{"content":"hello"}}]}\n',
                    b'data: {"choices":[],"usage":{"prompt_tokens":4168,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":0}}}\n',
                    b'data: [DONE]\n',
                ])

        result = {}
        with patch.object(serve_load.urllib.request, "urlopen", return_value=Response()) as open_url:
            serve_load.one("http://127.0.0.1:8188", "", "strata", 0, 800, 256, result, {}, False,
                           " run-1-0", "source text")
        self.assertEqual(result[0]["prompt_tokens"], 4168)
        self.assertEqual(result[0]["tokens"], 1)
        self.assertEqual(result[0]["cached_tokens"], 0)
        self.assertIsNone(result[0]["err"])
        self.assertIn("source text", json.loads(open_url.call_args.args[0].data)["messages"][0]["content"])

    def test_overlap_requires_simultaneous_output_intervals(self):
        queued = [{"first_at": 1.0, "end_at": 2.0}, {"first_at": 2.2, "end_at": 3.0}]
        simultaneous = [{"first_at": 1.0, "end_at": 2.5}, {"first_at": 1.5, "end_at": 3.0}]
        self.assertEqual(serve_load.output_overlap_seconds(queued), 0)
        self.assertAlmostEqual(serve_load.output_overlap_seconds(simultaneous), 1.0)

    def test_load_rejects_cache_reuse_or_no_output_overlap(self):
        with TemporaryDirectory(dir=Path.cwd()) as folder:
            root = Path(folder)
            (root / "README.md").write_text("Benchmark source. " * 100, encoding="utf-8")
            dirs = SimpleNamespace(root=root, prompts=root / "prompts", logs=root / "logs")
            dirs.prompts.mkdir(); dirs.logs.mkdir()
            server = SimpleNamespace(snapshot=SimpleNamespace(model_id="test", model_name="Test", path=root / "config.json", port=8188))
            paths = SimpleNamespace(root=root, python=Path("python"))
            for cached, overlap in ((1, 0.5), (0, 0.0)):
                def fake_tool(command, *_, **__):
                    Path(command[command.index("--json") + 1]).write_text(json.dumps([{
                        "clients": 2, "errors": 0, "prompt_tokens_min": 4100,
                        "prompt_tokens_max": 4110, "prompt_token_samples": 2,
                        "cached_tokens_max": cached, "cached_token_samples": 2,
                        "output_overlap_seconds": overlap}]), encoding="utf-8")
                    return 0
                with patch.object(official_tools, "build_measured_prompt", return_value=("source text", root / "source.txt")), \
                     patch.object(official_tools, "_run_owned_tool", side_effect=fake_tool):
                    row = official_tools.run_load(server, paths, dirs, 1, "run", [2], rounds=1,
                                                  context_cases=[("4k", 4014)])[0]
                self.assertEqual(row["status"], "failure")
                self.assertTrue(row["error"])

    def test_completion_requires_every_selected_load_length_and_client_count(self):
        request = {"stages": ["load"], "models": [{"model_id": "test"}],
                   "load_prompt_mode": "selected_lengths", "load_input_lengths": ["4k", "32k"],
                   "load_clients": [1, 2]}
        self.assertEqual(_expected_stage_records(request, "load", []), 4)
        rows = [{"model_id": "test", "stage": "load", "status": "success",
                 "case_id": f"load-{length}-clients-{clients}"}
                for length in ("4k", "32k") for clients in (1, 2)]
        self.assertEqual(assess_completion(request, rows)["models"]["test"]["stages"]["load"]["state"], "completed")
        self.assertEqual(assess_completion(request, rows[:2])["models"]["test"]["stages"]["load"]["state"], "partial")

    def test_load_fails_when_measured_prompt_is_far_from_selected_length(self):
        with TemporaryDirectory(dir=Path.cwd()) as folder:
            root = Path(folder)
            (root / "README.md").write_text("Benchmark source. " * 100, encoding="utf-8")
            dirs = SimpleNamespace(root=root, prompts=root / "prompts", logs=root / "logs")
            dirs.prompts.mkdir()
            dirs.logs.mkdir()
            server = SimpleNamespace(snapshot=SimpleNamespace(model_id="test", model_name="Test", path=root / "config.json", port=8188))
            paths = SimpleNamespace(root=root, python=Path("python"))

            def fake_tool(command, *_, **__):
                Path(command[command.index("--json") + 1]).write_text(
                    json.dumps([{"clients": 1, "errors": 0, "prompt_tokens_min": 9000,
                                 "prompt_tokens_max": 9000, "prompt_token_samples": 1}]), encoding="utf-8")
                return 0

            with patch.object(official_tools, "build_measured_prompt", return_value=("source text", root / "source.txt")), \
                 patch.object(official_tools, "_run_owned_tool", side_effect=fake_tool):
                row = official_tools.run_load(server, paths, dirs, 1, "run", [1], rounds=1,
                                              context_cases=[("4k", 4014)])[0]
            self.assertEqual(row["status"], "failure")
            self.assertIn("输入", row["error"])


if __name__ == "__main__":
    unittest.main()
