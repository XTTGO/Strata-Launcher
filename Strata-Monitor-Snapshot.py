"""One read-only, bounded Strata telemetry poll for the Windows overlay."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from pathlib import Path


def _number(value):
    return value if type(value) in (int, float) and math.isfinite(value) else None


def _label(value, limit=80):
    if not isinstance(value, str):
        return ""
    return "".join(c for c in value if c.isprintable())[:limit]


def view_model(snapshot):
    """Project the official sanitized snapshot onto fields the overlay displays."""
    model = snapshot.get("model") or {}
    work = snapshot.get("work") or {}
    rates = snapshot.get("rates") or {}
    topology = snapshot.get("topology") or {}
    ram = snapshot.get("ram") or {}
    devices = snapshot.get("devices") or []
    selected = topology.get("selected_devices") or []
    if selected:
        by_index = {}
        duplicate = set()
        for row in devices:
            if isinstance(row, dict):
                index = row.get("index")
                if type(index) is not int:
                    continue
                if index in by_index:
                    duplicate.add(index)
                by_index[index] = row
        for index in duplicate:
            by_index[index] = {"index": index}
        devices = [by_index.get(index, {"index": index}) for index in selected[:16]]
    gpu_rows = []
    for row in devices[:16]:
        if not isinstance(row, dict):
            continue
        gpu_rows.append({
            "index": _number(row.get("index")), "name": _label(row.get("name"), 48),
            "util": _number(row.get("util")), "mem_used": _number(row.get("mem_used")),
            "mem_total": _number(row.get("mem_total")), "temp": _number(row.get("temp")),
        })
    requests = []
    for row in sorted((r for r in (snapshot.get("recent") or []) if isinstance(r, dict)),
                      key=lambda r: _number(r.get("time")) or 0, reverse=True)[:5]:
        requests.append({
            "time": _number(row.get("time")), "finish": _label(row.get("finish"), 24),
            "prompt_tokens": _number(row.get("prompt_tokens")),
            "output_tokens": _number(row.get("output_tokens")),
            "duration_s": _number(row.get("duration_s")),
        })
    return {
        "ok": True, "source": _label(snapshot.get("source"), 32),
        "instance_id": _label((snapshot.get("instance") or {}).get("id"), 64),
        "model": _label(model.get("id")), "loaded": model.get("loaded") is True,
        "telemetry_available": (snapshot.get("quality") or {}).get("telemetry") != "unavailable",
        "answer_tok_s": _number(rates.get("answer_tok_s")),
        "prefill_tok_s": _number(rates.get("prefill_tok_s")),
        "active": _number(work.get("active")), "queued": _number(work.get("queued")),
        "devices": gpu_rows, "ram_used": _number(ram.get("used")),
        "ram_total": _number(ram.get("total")), "recent": requests,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strata-root", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("port must be between 1024 and 65535")
    sys.path.insert(0, str(args.strata_root.resolve()))
    from strata_cli.client import ClientError, Endpoint

    try:
        snapshot = Endpoint(
            f"http://127.0.0.1:{args.port}",
            credential=os.environ.get("STRATA_MONITOR_CREDENTIAL") or None,
            timeout=2.0,
        ).snapshot()
        result = view_model(snapshot)
    except ClientError as exc:
        kind = "auth" if exc.exit_code == 4 else "incompatible" if exc.exit_code == 5 else "disconnected"
        result = {"ok": False, "kind": kind, "message": str(exc)}
    except Exception:
        result = {"ok": False, "kind": "error", "message": "无法读取 Strata 遥测"}
    print(json.dumps(result, ensure_ascii=False, allow_nan=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
