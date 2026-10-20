"""Read the installed Strata setup catalog for launcher-only display names."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import urlparse

from benchmark.models import runtime_paths


def _publisher(spec: dict, model_spec: dict) -> str:
    source = str(model_spec.get("repo") or spec.get("hf") or "")
    if "/resolve/" in source:
        source = urlparse(source).path.lstrip("/").split("/resolve/", 1)[0]
    elif "://" in source:
        source = urlparse(source).path.lstrip("/")
    return source.split("/", 1)[0] if "/" in source else ""


def _source_label(family: str, model: str, spec: dict, model_spec: dict) -> str:
    publisher = _publisher(spec, model_spec)
    if family == "qwen" and publisher == "ISTA-DASLab" and "GSQ-RCO" in spec.get("file", "") and "ISTA-DASLab" in spec.get("by", ""):
        return "ISTA-DASLab GSQ-RCO"
    if family == "coder" and publisher == "ISTA-DASLab" and "GSQ-RCO" in spec.get("file", "") and "ISTA-DASLab" in spec.get("by", ""):
        return "ISTA-DASLab GSQ-RCO"
    if family == "swift" and publisher.lower() == "ukisai" and "GSQ-RCO" in spec.get("file", "") and "UkisAI" in spec.get("by", ""):
        return "UkisAI GSQ-RCO"
    if family == "unsloth" and publisher.lower() == "unsloth" and "Unsloth" in spec.get("by", ""):
        return "Unsloth"
    if family == "qwen36" and publisher.lower() == "unsloth" and "MTP-GGUF" in spec.get("hf", "") and "Unsloth" in spec.get("by", ""):
        return "Unsloth MTP"
    if family == "nvfp4" and model == "NVFP4" and model_spec.get("repo", "").endswith("NVFP4-GPTQ-Strata"):
        return "sergqwer GPTQ"
    if family == "nvfp4" and model == "NVFP4-NVIDIA" and model_spec.get("repo", "").endswith("NVIDIA-NVFP4-Strata"):
        return "NVIDIA; sergqwer conversion"
    return f"HF: {publisher}" if publisher else ""


def build_catalog(setup_module) -> list[dict[str, str]]:
    catalog = []
    for family, spec in setup_module.FAMILIES.items():
        for model, model_spec in setup_module.MODELS.items():
            if family not in model_spec.get("families", ("qwen", "swift")):
                continue
            name = f"{spec['name']}-{model.lower()}"
            source = _source_label(family, model, spec, model_spec)
            quant = "NVFP4" if family == "nvfp4" and model == "NVFP4-NVIDIA" and source == "NVIDIA; sergqwer conversion" else model
            title = spec["title"]
            if family == "nvfp4" and title.endswith(" (NVFP4)"):
                title = title[:-len(" (NVFP4)")]
            if source and title.endswith(f" ({source})"):
                label = f"{title} {quant}"
            else:
                label = f"{title} ({source}) {quant}" if source else name
            catalog.append({"model_name": name, "arch": "", "label": label})
    for family, spec in getattr(setup_module, "OWN_PATH_FAMILIES", {}).items():
        for model in spec["models"]:
            name = f"{spec['name']}-{model.lower()}"
            source = _source_label(family, model, spec, {})
            label = f"{spec['title']} ({source}) {model}" if source else name
            catalog.append({"model_name": name, "arch": str(spec.get("arch") or ""), "label": label})
    return catalog


if __name__ == "__main__":
    sys.path.insert(0, str(runtime_paths().root))
    import setup

    print(json.dumps(build_catalog(setup), ensure_ascii=True))
