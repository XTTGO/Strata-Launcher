import subprocess
import os
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(os.environ.get("STRATA_ROOT", Path(__file__).resolve().parents[2]))
HELPER = Path(__file__).resolve().parents[1] / "Strata-LocalModel-Inspect.py"


class LocalModelImportTests(unittest.TestCase):
    def run_helper(self, folder):
        return subprocess.run([sys.executable, str(HELPER), str(folder)], text=True, capture_output=True)

    def test_rejects_empty_directory_before_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_helper(directory)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("GGUF", result.stderr)

    def test_rejects_ambiguous_models_before_setup(self):
        sys.path.insert(0, str(ROOT))
        import setup
        families = [(family, model) for family, spec in setup.FAMILIES.items()
                    for model in setup.MODELS if family in setup.MODELS[model].get("families", ("qwen", "swift"))]
        self.assertGreaterEqual(len(families), 2)
        with tempfile.TemporaryDirectory() as directory:
            for family, model in families[:2]:
                Path(directory, setup.model_file(setup.FAMILIES[family], model, 1)).touch()
            result = self.run_helper(directory)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("multiple", result.stderr)

    def test_recognizes_one_model_then_checks_shards(self):
        sys.path.insert(0, str(ROOT))
        import setup
        family = next(iter(setup.FAMILIES))
        model = next(model for model in setup.MODELS
                     if family in setup.MODELS[model].get("families", ("qwen", "swift")))
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, setup.model_file(setup.FAMILIES[family], model, 1)).touch()
            result = self.run_helper(directory)
        self.assertNotEqual(0, result.returncode)
        self.assertTrue((result.stdout + result.stderr).strip())

    def test_multi_file_model_is_recognized_and_checked(self):
        sys.path.insert(0, str(ROOT))
        import setup
        family, spec = next(iter(setup.MULTI_FILE_FAMILIES.items()))
        model, meta = next(iter(spec["models"].items()))
        with tempfile.TemporaryDirectory() as directory:
            for name in [*meta["shards"], *meta.get("shared", [])]:
                Path(directory, name).touch()
            result = self.run_helper(directory)
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("No GGUF filename", result.stderr)
        self.assertNotIn("multiple", result.stderr)
        self.assertIn("size", result.stderr.lower())

    def test_own_path_model_is_recognized_and_size_checked(self):
        sys.path.insert(0, str(ROOT))
        import setup
        own = setup.OWN_PATH_FAMILIES["qwen36"]
        filename = own["file"].format(q=next(iter(own["models"])))
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, filename).touch()
            result = self.run_helper(directory)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("size", result.stderr.lower())
        self.assertNotIn("No GGUF filename", result.stderr)


if __name__ == "__main__":
    unittest.main()
