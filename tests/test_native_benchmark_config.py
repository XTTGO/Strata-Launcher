import json
import tempfile
import unittest
from pathlib import Path

from launcher.benchmark.models import ModelProfile, is_qwen36_own_path, snapshot_profile


class NativeBenchmarkConfigTests(unittest.TestCase):
    def test_flash_next_native_arg_is_not_qwen36(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {"args": ["--pack", "pack", "--native", "flash.gguf",
                               "--max-context", "262144", "--kv", "int8"],
                      "exe": "strata.exe", "model_name": "qwen3.8-flash-next-iq3_s"}
            self.assertFalse(is_qwen36_own_path(config))
            raw = json.dumps(config).encode()
            source = root / "source.json"
            source.write_bytes(raw)
            import hashlib
            profile = ModelProfile("flash", "Flash-Next", source, hashlib.sha256(raw).hexdigest(), raw, config, 8080)
            result = snapshot_profile(profile, root / "configs", 8188, 1,
                                      {"--max-context": "524288", "--rope-scaling": "yarn", "--kv": "q4_0"})
            self.assertEqual(result.config["args"][result.config["args"].index("--max-context") + 1], "524288")
            self.assertEqual(result.config["args"][result.config["args"].index("--kv") + 1], "q4_0")
            self.assertIn("--rope-scaling", result.config["args"])

    def test_native_context_rejects_yarn_and_preserves_mtp(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {"arch": "qwen35moe", "args": ["--native", "model.gguf", "--max-context", "131072",
                      "--prefill", "auto", "--mtp", "2"], "exe": "strata.exe", "model_name": "Qwen3.6"}
            self.assertTrue(is_qwen36_own_path(config))
            raw = json.dumps(config).encode()
            source = root / "source.json"
            source.write_bytes(raw)
            import hashlib
            profile = ModelProfile("qwen36", "Qwen3.6", source, hashlib.sha256(raw).hexdigest(), raw, config, 8080)
            with self.assertRaises(ValueError):
                snapshot_profile(profile, root / "configs", 8188, 1,
                                 {"--max-context": "524288", "--rope-scaling": "yarn"})
            result = snapshot_profile(profile, root / "configs", 8188, 1, {"--max-context": "262144"})
            self.assertEqual(result.config["args"][-2:], ["--mtp", "2"])
            self.assertNotIn("--rope-scaling", result.config["args"])

    def test_benchmark_snapshot_never_saves_expert_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {"args": ["--expert-profile-save", "user.bin", "--max-context", "131072"],
                      "exe": "strata.exe", "model_name": "M"}
            raw = json.dumps(config).encode()
            source = root / "source.json"
            source.write_bytes(raw)
            import hashlib
            profile = ModelProfile("m", "M", source, hashlib.sha256(raw).hexdigest(), raw, config, 8080)
            result = snapshot_profile(profile, root / "configs", 8188, 1)
            self.assertNotIn("--expert-profile-save", result.config["args"])
            self.assertEqual(result.config["args"], ["--max-context", "131072"])
            self.assertEqual(json.loads(source.read_text()), config)


if __name__ == "__main__":
    unittest.main()
