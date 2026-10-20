"""Inspect a local GGUF folder against the installed Strata setup model table."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from benchmark.models import runtime_paths


def inspect_folder(folder: Path) -> dict[str, object]:
    root = runtime_paths().root
    sys.path.insert(0, str(root))
    import setup

    if not folder.is_dir():
        raise ValueError("Local model directory does not exist")
    ggufs = [path for path in folder.iterdir() if path.is_file() and path.suffix.lower() == ".gguf"
             and not path.name.lower().startswith("mmproj")]
    if not ggufs:
        raise ValueError("No GGUF model files found in the selected directory")
    choices = set(choice for path in ggufs if (choice := setup.gguf_choice(path.name)))
    for family, spec in getattr(setup, "OWN_PATH_FAMILIES", {}).items():
        for model in spec["models"]:
            if any(path.name == spec["file"].format(q=model) for path in ggufs):
                choices.add((family, model))
    choices = sorted(choices)
    if not choices:
        raise ValueError("No GGUF filename matches a model supported by this Strata setup version")
    if len(choices) != 1:
        raise ValueError("Found multiple supported models in one directory; select a directory with one model")
    family, model = choices[0]
    if family in getattr(setup, "OWN_PATH_FAMILIES", {}):
        spec = setup.OWN_PATH_FAMILIES[family]
        path = folder / spec["file"].format(q=model)
        expected_size = spec["sha256"][path.name][0]
        if path.stat().st_size != expected_size:
            raise ValueError(f"GGUF size mismatch for {path.name}: expected {expected_size} bytes")
        shards = [path]
    else:
        shards = setup.gguf_dir_shards(folder, setup.FAMILIES[family], model)
        setup.check_shards(shards)
    unexpected = sorted(path.name for path in ggufs if path not in shards)
    if unexpected:
        raise ValueError("The directory contains other GGUF model files: " + ", ".join(unexpected[:3]))
    return {"family": family, "model": model, "shards": len(shards),
            "filenames": [path.name for path in shards], "sha256_pending": family in getattr(setup, "OWN_PATH_FAMILIES", {})}


if __name__ == "__main__":
    try:
        print(json.dumps(inspect_folder(Path(sys.argv[1])), ensure_ascii=False))
    except (IndexError, ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2) from None
