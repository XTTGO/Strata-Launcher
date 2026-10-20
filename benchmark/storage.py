from __future__ import annotations

import json
import os
import time
import uuid
import warnings
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import SCHEMA_VERSION


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@dataclass(frozen=True)
class RunDirectories:
    root: Path
    configs: Path
    prompts: Path
    answers: Path
    logs: Path
    manifest: Path
    status: Path
    records: Path
    hardware: Path
    cancel: Path


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        for attempt in range(5):
            try:
                os.replace(temp, path)
                return
            except PermissionError:
                if attempt == 4:
                    raise
                time.sleep(0.05 * (attempt + 1))
    finally:
        try:
            temp.unlink(missing_ok=True)
        except OSError:
            pass


def read_json(path: Path, fallback: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError, json.JSONDecodeError):
        return fallback


def create_run_directories(report_root: Path, preset: str, request: dict[str, Any]) -> RunDirectories:
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    base = report_root / f"{stamp}_{preset}"
    suffix = 2
    while base.exists():
        base = report_root / f"{stamp}_{preset}_{suffix}"
        suffix += 1
    configs = base / "configs"
    prompts = base / "prompts"
    answers = base / "answers"
    logs = base / "logs"
    for directory in (configs, prompts, answers, logs):
        directory.mkdir(parents=True, exist_ok=False)
    dirs = RunDirectories(
        root=base,
        configs=configs,
        prompts=prompts,
        answers=answers,
        logs=logs,
        manifest=base / "run-manifest.json",
        status=base / "status.json",
        records=base / "raw-results.jsonl",
        hardware=base / "hardware.json",
        cancel=base / "cancel.request",
    )
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "run_id": str(uuid.uuid4()),
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "state": "preparing",
        "request": request,
        "stages": {},
        "errors": [],
    }
    atomic_json(dirs.manifest, manifest)
    write_status(dirs, state="preparing", message="正在准备测试")
    return dirs


def update_manifest(dirs: RunDirectories, **changes: Any) -> dict[str, Any]:
    manifest = read_json(dirs.manifest, {}) or {}
    manifest.update(changes)
    manifest["updated_at"] = utc_now()
    atomic_json(dirs.manifest, manifest)
    return manifest


def write_status(dirs: RunDirectories, **status: Any) -> bool:
    current = read_json(dirs.status, {}) or {}
    current.update(status)
    current["updated_at"] = utc_now()
    try:
        atomic_json(dirs.status, current)
    except PermissionError as exc:
        warnings.warn(f"状态文件更新失败，Benchmark 将继续：{exc}", RuntimeWarning, stacklevel=2)
        return False
    return True


def append_record(dirs: RunDirectories, record: dict[str, Any]) -> str:
    record = dict(record)
    record.setdefault("schema_version", SCHEMA_VERSION)
    record.setdefault("record_id", str(uuid.uuid4()))
    record.setdefault("recorded_at", utc_now())
    with dirs.records.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    return str(record["record_id"])


def request_cancel(dirs: RunDirectories, requester_pid: int | None = None) -> None:
    atomic_json(dirs.cancel, {"requested_at": utc_now(), "requester_pid": requester_pid})


def is_cancelled(dirs: RunDirectories) -> bool:
    return dirs.cancel.exists()


def open_existing_run(path: Path) -> RunDirectories:
    path = path.resolve()
    return RunDirectories(
        root=path,
        configs=path / "configs",
        prompts=path / "prompts",
        answers=path / "answers",
        logs=path / "logs",
        manifest=path / "run-manifest.json",
        status=path / "status.json",
        records=path / "raw-results.jsonl",
        hardware=path / "hardware.json",
        cancel=path / "cancel.request",
    )

