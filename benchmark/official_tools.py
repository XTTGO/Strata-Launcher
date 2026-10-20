from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path
from typing import Any

import psutil

from .models import RuntimePaths
from .processes import CREATE_NEW_PROCESS_GROUP, OwnedServer
from .storage import RunDirectories, is_cancelled
from .workloads import StrataClient, build_measured_prompt, build_prompt


LOAD_ROUNDS = 3
LOAD_MAX_TOKENS = 256
LOAD_WORDS = 800


def benchmark_tool_path(paths: RuntimePaths, name: str) -> Path:
    launcher = getattr(paths, "launcher", paths.root / "launcher")
    bundled = launcher / "benchmark" / "tools" / name
    return bundled if bundled.is_file() else paths.root / "tools" / name


def _run_owned_tool(command: list[str], cwd: Path, log_path: Path, dirs: RunDirectories, timeout: int) -> int:
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            stdout=log,
            stderr=subprocess.STDOUT,
            creationflags=CREATE_NEW_PROCESS_GROUP,
        )
        create_time = psutil.Process(process.pid).create_time()
        deadline = time.monotonic() + timeout
        while process.poll() is None:
            if is_cancelled(dirs) or time.monotonic() >= deadline:
                try:
                    root = psutil.Process(process.pid)
                    if abs(root.create_time() - create_time) < 0.01:
                        children = root.children(recursive=True)
                        for item in children + [root]:
                            try:
                                item.terminate()
                            except psutil.Error:
                                pass
                        _, alive = psutil.wait_procs(children + [root], timeout=10)
                        for item in alive:
                            try:
                                item.kill()
                            except psutil.Error:
                                pass
                except psutil.Error:
                    pass
                return 130 if is_cancelled(dirs) else 124
            time.sleep(0.5)
        return int(process.returncode or 0)


def run_needle(
    server: OwnedServer,
    paths: RuntimePaths,
    dirs: RunDirectories,
    round_number: int,
    run_id: str,
    lengths: list[str],
    depths: list[int] | None = None,
) -> list[dict[str, Any]]:
    depths = depths or [10, 50, 90]
    out_path = dirs.root / f"needle-{server.snapshot.model_id}-round-{round_number}.json"
    log_path = dirs.logs / f"needle-{server.snapshot.model_id}-round-{round_number}.log"
    command = [
        str(paths.python),
        str(benchmark_tool_path(paths, "needle_bench.py")),
        "--url",
        f"http://127.0.0.1:{server.snapshot.port}",
        "--lengths",
        ",".join(lengths),
        "--depths",
        ",".join(str(x) for x in depths),
        "--timeout",
        "1800",
        "--calibrate-length",
        "--out",
        str(out_path),
    ]
    exit_code = _run_owned_tool(command, paths.root, log_path, dirs, timeout=7200)
    try:
        rows = json.loads(out_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError, json.JSONDecodeError):
        rows = []
    records = []
    for index, row in enumerate(rows if isinstance(rows, list) else []):
        label = str(row.get("length") or "")
        try:
            nominal = int(float(label[:-1]) * 1024) if label.lower().endswith("k") else int(label)
            target = int(nominal * 0.98)
        except ValueError:
            target = None
        actual = row.get("prompt_tokens")
        problem = None
        if row.get("error"):
            problem = str(row["error"])
        elif row.get("found") is not True and row.get("found") is not False:
            problem = "Needle 测试缺少召回判定"
        elif target is None or not isinstance(actual, int) or not target * 0.95 <= actual <= target * 1.05:
            problem = f"Needle 输入实测 {actual} tokens，偏离所选 {label} 档位目标 {target} 超过 5%"
        status = "failure" if problem or row.get("found") is False else "success"
        records.append(
            {
                "run_id": run_id,
                "model_id": server.snapshot.model_id,
                "model_name": server.snapshot.model_name,
                "config_snapshot": str(server.snapshot.path),
                "round": round_number,
                "stage": "needle",
                "case_id": f"needle-{row.get('length', index)}-{row.get('depth', index)}",
                **row,
                "status": status,
                **({"error": problem} if problem else {}),
                "target_tokens": target,
                "tool_exit_code": exit_code,
                "tool_output": str(out_path),
                "tool_log": str(log_path),
            }
        )
    if not records:
        records.append(
            {
                "run_id": run_id,
                "model_id": server.snapshot.model_id,
                "model_name": server.snapshot.model_name,
                "config_snapshot": str(server.snapshot.path),
                "round": round_number,
                "stage": "needle",
                "case_id": "needle-tool",
                "status": "failure" if exit_code else "skipped",
                "tool_exit_code": exit_code,
                "tool_output": str(out_path),
                "tool_log": str(log_path),
                "error": "官方 Needle 工具未产生可解析结果",
            }
        )
    return records


def run_load(
    server: OwnedServer,
    paths: RuntimePaths,
    dirs: RunDirectories,
    round_number: int,
    run_id: str,
    clients: list[int],
    rounds: int = LOAD_ROUNDS,
    context_cases: list[tuple[str, int]] | None = None,
) -> list[dict[str, Any]]:
    records = []
    # Direct callers can still request the tool's historical short-prompt mode.
    cases = context_cases if context_cases is not None else [(None, None)]
    for label, target in cases:
        suffix = f"-{label}" if label else ""
        out_path = dirs.root / f"load-{server.snapshot.model_id}-round-{round_number}{suffix}.json"
        log_path = dirs.logs / f"load-{server.snapshot.model_id}-round-{round_number}{suffix}.log"
        command = [
        str(paths.python),
        str(benchmark_tool_path(paths, "serve_load.py")),
        f"http://127.0.0.1:{server.snapshot.port}",
        "--clients",
        ",".join(str(x) for x in clients),
        "--rounds",
        str(rounds),
        "--max-tokens",
        str(LOAD_MAX_TOKENS),
        "--words",
        str(LOAD_WORDS),
        "--nonce",
        run_id,
        "--json",
        str(out_path),
        ]
        prompt_path = None
        if label:
            prompt, _ = build_measured_prompt(paths.root, dirs, StrataClient(server.snapshot.port),
                                              int(target), str(label), server.snapshot.model_id)
            prompt_path = dirs.prompts / f"load-prompt-{server.snapshot.model_id}-{label}.txt"
            prompt_path.write_text(prompt.rsplit("\n\n请用三句话总结上面的资料。", 1)[0], encoding="utf-8")
            command += ["--prompt-file", str(prompt_path)]
        exit_code = _run_owned_tool(command, paths.root, log_path, dirs, timeout=7200)
        try:
            rows = json.loads(out_path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError, json.JSONDecodeError):
            rows = []
        for row in rows if isinstance(rows, list) else []:
            samples = row.get("prompt_token_samples")
            expected_samples = int(row.get("clients") or 0) * rounds
            low, high = row.get("prompt_tokens_min"), row.get("prompt_tokens_max")
            input_error = None
            if label:
                if samples != expected_samples or not isinstance(low, int) or not isinstance(high, int):
                    input_error = "并发输入缺少服务返回的实测 token 数，无法核验所选档位"
                elif not (int(target) * 0.90 <= low <= high <= int(target) * 1.10):
                    input_error = f"并发输入实测 {low}–{high} tokens，明显偏离所选 {label} 档位目标 {target}"
                elif row.get("cached_token_samples") != expected_samples or not isinstance(row.get("cached_tokens_max"), int):
                    input_error = "并发输入缺少缓存复用计数，无法核验冷提示词"
                elif row["cached_tokens_max"] != 0:
                    input_error = f"并发输入复用 {row['cached_tokens_max']} tokens，冷提示词条件不成立"
                elif int(row.get("clients") or 0) > 1 and not (isinstance(row.get("output_overlap_seconds"), (int, float)) and row["output_overlap_seconds"] > 0):
                    input_error = "并发请求的输出时间未重叠，无法证实同时运行"
            records.append(
            {
                "run_id": run_id,
                "model_id": server.snapshot.model_id,
                "model_name": server.snapshot.model_name,
                "config_snapshot": str(server.snapshot.path),
                "round": round_number,
                "stage": "load",
                "case_id": f"load-{label}-clients-{row.get('clients')}" if label else f"clients-{row.get('clients')}",
                "status": "failure" if row.get("errors") or exit_code or input_error else "success",
                **({"error": input_error} if input_error else {}),
                **({"input_length": label, "target_tokens": target, "prompt_file": str(prompt_path)} if label else {}),
                "tool_exit_code": exit_code,
                "tool_output": str(out_path),
                "tool_log": str(log_path),
                **row,
            }
            )
        if not isinstance(rows, list) or not rows:
            records.append(
            {
                "run_id": run_id,
                "model_id": server.snapshot.model_id,
                "model_name": server.snapshot.model_name,
                "config_snapshot": str(server.snapshot.path),
                "round": round_number,
                "stage": "load",
                "case_id": f"load-{label}-tool" if label else "load-tool",
                "status": "failure",
                "tool_exit_code": exit_code,
                "tool_output": str(out_path),
                "tool_log": str(log_path),
                "error": "官方并发工具未产生可解析结果",
            }
            )
    return records

