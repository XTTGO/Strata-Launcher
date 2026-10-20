from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

from launcher.benchmark import storage
from launcher.benchmark import runner


class AtomicStorage(unittest.TestCase):
    def test_atomic_json_retries_transient_windows_replace_denial(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            target = Path(folder) / "status.json"
            real_replace = storage.os.replace
            attempts = 0

            def replace_after_two_denials(source, destination):
                nonlocal attempts
                attempts += 1
                if attempts < 3:
                    raise PermissionError(5, "access denied", str(destination))
                real_replace(source, destination)

            with patch.object(storage.os, "replace", side_effect=replace_after_two_denials):
                storage.atomic_json(target, {"state": "running"})

            self.assertEqual(attempts, 3)
            self.assertEqual(json.loads(target.read_text(encoding="utf-8")), {"state": "running"})
            self.assertEqual(list(Path(folder).glob("*.tmp")), [])

    def test_write_status_reports_a_persistent_permission_error_without_raising(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            dirs = storage.create_run_directories(Path(folder), "test", {"stages": []})
            with patch("launcher.benchmark.storage.atomic_json", side_effect=PermissionError("locked")):
                with self.assertWarnsRegex(RuntimeWarning, "状态文件更新失败"):
                    result = storage.write_status(dirs, state="running")

        self.assertFalse(result)

    def test_status_file_lock_does_not_skip_a_benchmark_stage(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            dirs = storage.create_run_directories(Path(folder), "test", {"stages": ["stability"]})
            real_atomic_json = storage.atomic_json
            profile = SimpleNamespace(model_id="model-a", model_name="Model A")
            ran = []

            def deny_status_replace(path, value):
                if path == dirs.status:
                    raise PermissionError("status file is locked")
                real_atomic_json(path, value)

            with patch("launcher.benchmark.storage.atomic_json", side_effect=deny_status_replace):
                with self.assertWarns(RuntimeWarning):
                    runner._run_stage(
                        dirs,
                        "run-1",
                        profile,
                        1,
                        "stability",
                        lambda: ran.append(True) or {"model_id": "model-a", "stage": "stability", "status": "success"},
                    )

            records, errors = runner.read_records(dirs.records)

        self.assertEqual(errors, [])
        self.assertEqual(ran, [True])
        self.assertEqual([row["status"] for row in records], ["success"])


if __name__ == "__main__":
    unittest.main()
