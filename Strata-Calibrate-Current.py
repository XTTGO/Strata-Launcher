"""Run Strata's built-in calibration for one existing run config.

This deliberately calls the setup module's calibration writer directly.  It
does not run the setup/update path, so it neither downloads nor upgrades the
engine or model.
"""

from pathlib import Path
import json
import os
import sys
import time

from benchmark.models import runtime_paths

ROOT = runtime_paths().root
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import setup


DETAILS_PATH = ROOT / "launcher" / "data" / "calibration-details.json"
ENGINE_DEFAULTS = {
    "--adapt-every": "4",
    "--adapt-swaps": "96",
    "--adapt-decay": "0.70",
}


def write_detail_record(path: Path, key: str, record: dict) -> None:
    """Atomically add one combination's detailed report without replacing the others."""
    try:
        store = json.loads(path.read_text(encoding="utf-8-sig")) if path.is_file() else {}
    except (OSError, json.JSONDecodeError):
        store = {}
    if not isinstance(store, dict):
        store = {}
    records = store.setdefault("records", {})
    if not isinstance(records, dict):
        records = store["records"] = {}
    store["schema_version"] = 1
    records[key] = record
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(store, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def calibrate_with_detail(config_path: Path) -> bool:
    """Run the official writer and retain the report it normally summarizes away."""
    tools_dir = ROOT / "tools"
    if str(tools_dir) not in sys.path:
        sys.path.insert(0, str(tools_dir))
    import calibrate

    captured = {}
    original_run = calibrate.run

    def capture_run(*args, **kwargs):
        result = original_run(*args, **kwargs)
        captured["result"] = result
        return result

    calibrate.run = capture_run
    try:
        ok = setup.calibrate_config(config_path)
    finally:
        calibrate.run = original_run
    if not ok or "result" not in captured:
        return ok

    cfg = json.loads(config_path.read_text(encoding="utf-8-sig"))
    result = captured["result"]
    try:
        version = ".".join(str(x) for x in setup.engine_version(cfg["exe"]))
    except Exception:
        version = "unknown"
    record = {
        "date": time.strftime("%Y-%m-%d"),
        "engine_version": version,
        "engine_defaults": ENGINE_DEFAULTS,
        "settings": result.get("settings") or {},
        "report": result.get("report") or {},
    }
    try:
        write_detail_record(DETAILS_PATH, setup.hardware_key(cfg), record)
        print(f"  detailed calibration report: {DETAILS_PATH}")
    except Exception as exc:
        print(f"  warning: calibration succeeded, but its detailed launcher report was not saved ({exc})")
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: Strata-Calibrate-Current.py <strata-*.json>")
        return 2

    config_path = Path(sys.argv[1]).resolve()
    if not config_path.is_file():
        print(f"config not found: {config_path}")
        return 2

    return 0 if calibrate_with_detail(config_path) else 1


if __name__ == "__main__":
    raise SystemExit(main())
