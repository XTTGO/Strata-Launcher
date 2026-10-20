import importlib.util
import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(os.environ.get("STRATA_ROOT", Path(__file__).resolve().parents[2]))
HELPER = Path(__file__).resolve().parents[1] / "model_catalog.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("launcher_model_catalog", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ModelCatalogTests(unittest.TestCase):
    def test_current_setup_catalog_preserves_quantization_sources(self):
        sys.path.insert(0, str(ROOT))
        import setup

        labels = {entry["model_name"]: entry["label"]
                  for entry in load_helper().build_catalog(setup)}
        expected_names = {
            f"{spec['name']}-{model.lower()}"
            for family, spec in setup.FAMILIES.items()
            for model, model_spec in setup.MODELS.items()
            if family in model_spec.get("families", ("qwen", "swift"))
        }
        expected_names.update(
            f"{spec['name']}-{model.lower()}"
            for spec in getattr(setup, "OWN_PATH_FAMILIES", {}).values()
            for model in spec["models"]
        )
        self.assertEqual(expected_names, set(labels))
        self.assertEqual("Qwen3.8-Flash-Next (ISTA-DASLab GSQ-RCO) IQ3_S",
                         labels["qwen3.8-flash-next-iq3_s"])
        self.assertEqual("Qwen3.8-Flash-Next (Unsloth) Q8_0",
                         labels["qwen3.8-flash-next-unsloth-q8_0"])
        self.assertEqual("Qwen3.8-Flash-Next (sergqwer GPTQ) NVFP4",
                         labels["qwen3.8-flash-next-nvfp4-nvfp4"])
        self.assertEqual("Qwen3.8-Flash-Next (NVIDIA; sergqwer conversion) NVFP4",
                         labels["qwen3.8-flash-next-nvfp4-nvfp4-nvidia"])

    def test_future_family_is_extracted_with_publisher_provenance(self):
        fake = SimpleNamespace(
            MODELS={"IQ4": {"families": ("new",)}},
            FAMILIES={"new": {"name": "new-model", "title": "New Model",
                              "hf": "https://huggingface.co/NewPublisher/NewRepo/resolve/rev/"}},
            OWN_PATH_FAMILIES={},
        )
        self.assertEqual(
            [{"model_name": "new-model-iq4", "arch": "", "label": "New Model (HF: NewPublisher) IQ4"}],
            load_helper().build_catalog(fake),
        )

    def test_model_repository_overrides_family_source(self):
        fake = SimpleNamespace(
            MODELS={"IQ4": {"families": ("qwen",), "repo": "OtherPublisher/NewQuant"}},
            FAMILIES={"qwen": {"name": "qwen3.8-flash-next", "title": "Qwen3.8-Flash-Next",
                                "hf": "https://huggingface.co/ISTA-DASLab/Original/resolve/rev/",
                                "file": "Qwen3.8-Flash-Next-GSQ-RCO-{q}.gguf"}},
            OWN_PATH_FAMILIES={},
        )
        self.assertEqual("Qwen3.8-Flash-Next (HF: OtherPublisher) IQ4",
                         load_helper().build_catalog(fake)[0]["label"])

    def test_without_provenance_keeps_original_name(self):
        fake = SimpleNamespace(
            MODELS={"IQ4": {"families": ("new",)}},
            FAMILIES={"new": {"name": "new-model", "title": "New Model"}},
            OWN_PATH_FAMILIES={},
        )
        self.assertEqual("new-model-iq4", load_helper().build_catalog(fake)[0]["label"])


if __name__ == "__main__":
    unittest.main()
