from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import traceback
import urllib.request
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable

import psutil

from .agent_eval import load_cases, run_agent_case
from .capacity import run_capacity_probe
from .models import ModelProfile, discover_profiles, is_qwen36_own_path, profile_to_dict, revalidate_profile, runtime_paths, snapshot_profile
from .official_tools import LOAD_MAX_TOKENS, LOAD_ROUNDS, LOAD_WORDS, benchmark_tool_path, run_load, run_needle
from .processes import CREATE_NO_WINDOW, OwnedServer, ensure_ports_free, query_nvidia, start_server, stop_server
from .report import assess_completion, read_records, render_reports
from .storage import (
    RunDirectories,
    append_record,
    atomic_json,
    create_run_directories,
    is_cancelled,
    open_existing_run,
    read_json,
    request_cancel,
    update_manifest,
    utc_now,
    write_status,
)
from .uniform import normalize_uniform_config, validate_uniform_compatibility
from .workloads import CacheCase, PerformanceCase, StrataClient, run_cache_sequence, run_performance, run_stability, warm_up


PRESETS: dict[str, dict[str, Any]] = {
    "standard": {
        "label": "日常速测",
        "performance": [("1k", 1024), ("4k", 4014)],
        "stages": ["performance", "cache", "agent", "needle", "load"],
        "needle_lengths": ["4k"],
        "load_lengths": ["4k"],
        "context_tier": 262144,
        "rounds": 1,
        "load_rounds": 1,
        "load_clients": [1, 2],
        "stability_requests": 0,
    },
    "full": {
        "label": "日常完整",
        "performance": [("1k", 1024), ("4k", 4014), ("32k", 32112)],
        "stages": ["performance", "cache", "agent", "needle", "load", "stability"],
        "needle_lengths": ["4k", "32k"],
        "load_lengths": ["4k"],
        "context_tier": 262144,
        "rounds": 3,
        "load_rounds": 3,
        "load_clients": [1, 2],
        "stability_requests": 10,
    },
    "long": {
        "label": "长文对照",
        "performance": [("32k", 32112), ("128k", 128450)],
        "stages": ["performance", "needle"],
        "needle_lengths": ["32k", "128k"],
        "load_lengths": [],
        "context_tier": 262144,
        "rounds": 1,
        "load_rounds": 1,
        "load_clients": [1, 2],
        "stability_requests": 0,
    },
    "parallel": {
        "label": "并发专项",
        "performance": [("4k", 4014), ("32k", 32112)],
        "stages": ["load"],
        "needle_lengths": [],
        "load_lengths": ["4k", "32k"],
        "context_tier": 262144,
        "rounds": 1,
        "load_rounds": 2,
        "load_clients": [1, 2],
        "stability_requests": 0,
    },
    "capacity": {
        "label": "容量极限",
        "performance": [("256k", 256901)],
        "stages": ["performance", "needle", "capacity"],
        "needle_lengths": ["256k"],
        "load_lengths": [],
        "context_tier": 262144,
        "rounds": 1,
        "load_rounds": 1,
        "load_clients": [1, 2],
        "stability_requests": 0,
    },
}

STABILITY_REQUESTS = 10

CONTEXT_CASES: dict[str, tuple[int, str]] = {
    "1k": (1024, "1k"),
    "4k": (4014, "4k"),
    "32k": (32112, "32k"),
    "128k": (128450, "128k"),
    "256k": (256901, "256k"),
}

MODEL_CONTEXT_CHOICES = (32768, 65536, 131072, 262144, 393216, 524288)
NATIVE_CONTEXT_LIMIT = 262144


@dataclass(frozen=True)
class ContextVariant:
    profile: ModelProfile
    source_model_id: str
    context_tier: int | None


def build_context_variants(
    profiles: list[ModelProfile], tiers: list[int | None], legacy_single: bool = False
) -> list[ContextVariant]:
    variants: list[ContextVariant] = []
    used: set[str] = set()
    for source in profiles:
        for cap in tiers:
            base = source.model_id if cap is None or legacy_single else f"{source.model_id}-ctx-{cap // 1024}k"
            model_id = base
            suffix = 2
            while model_id in used:
                model_id = f"{base}-{suffix}"
                suffix += 1
            used.add(model_id)
            variants.append(ContextVariant(replace(source, model_id=model_id), source.model_id, cap))
    return variants


def resolve_context_tiers(
    selected: list[int] | None, sweep: bool, legacy_max_context: int | None = None
) -> tuple[list[int | None], list[int]]:
    """Return explicit caps in ascending order; never silently ignore a checked cap."""
    if selected is None:
        selected = [legacy_max_context] if legacy_max_context is not None else []
    tiers = [int(value) for value in selected]
    if len(tiers) != len(set(tiers)):
        raise ValueError("模型上限档位不能重复选择")
    if any(tier not in MODEL_CONTEXT_CHOICES for tier in tiers):
        raise ValueError("模型上限包含未知档位")
    tiers.sort()
    if sweep and len(tiers) < 2:
        raise ValueError("多档上限测试至少选择两个模型上限档位")
    if not tiers:
        return [None], []
    if not sweep and len(tiers) > 1:
        raise ValueError("已选择多个模型上限；请开启多档上限测试，或只保留一个档位")
    return tiers, []


def _selected_tiers_from_args(args: argparse.Namespace) -> tuple[list[int | None], list[int], list[int]]:
    raw = getattr(args, "context_tiers", None)
    legacy = getattr(args, "max_context", None)
    if getattr(args, "source_context", False) and (raw is not None or legacy is not None):
        raise ValueError("--source-context 不能与 --context-tiers 或 --max-context 同时使用")
    if raw is not None and legacy is not None:
        raise ValueError("--context-tiers 与 --max-context 不能同时使用")
    selected = None if raw is None else [int(value.strip()) for value in raw.split(",") if value.strip()]
    effective, ignored = resolve_context_tiers(selected, bool(getattr(args, "sweep_context_tiers", False)), legacy)
    return effective, ignored, selected or ([legacy] if legacy is not None else [])


def apply_preset_defaults(args: argparse.Namespace) -> None:
    """Give CLI and GUI presets the same one-click rounds and native context cap."""
    if args.preset == "stress":
        raise ValueError("旧长文压力预设已拆分；请选择 long、parallel 或 capacity")
    preset = PRESETS[args.preset]
    if args.rounds is None:
        args.rounds = int(preset["rounds"])
    if args.context_tiers is None and args.max_context is None and not args.source_context:
        args.max_context = int(preset["context_tier"])


def resolve_model_context_overrides(max_context: int | None) -> dict[str, str]:
    """Build temporary config overrides; 512K uses the documented 2x YaRN extension."""
    if max_context is None:
        return {}
    value = int(max_context)
    if value not in MODEL_CONTEXT_CHOICES:
        raise ValueError("模型上下文上限必须是 32K、64K、128K、256K、384K 或 512K 实验档")
    overrides = {"--max-context": str(value)}
    if value > NATIVE_CONTEXT_LIMIT:
        overrides.update(
            {
                "--rope-scaling": "yarn",
                "--rope-scale": str(value / NATIVE_CONTEXT_LIMIT).rstrip("0").rstrip("."),
                "--yarn-orig-ctx": str(NATIVE_CONTEXT_LIMIT),
            }
        )
    return overrides


def resolve_load_clients(preset_name: str, maximum: int | None) -> list[int]:
    if maximum is None:
        return list(PRESETS[preset_name]["load_clients"])
    value = int(maximum)
    if value < 1 or value > 4:
        raise ValueError("最大并发数必须在 1 到 4 之间")
    return list(range(1, value + 1))


def resolve_stability_requests(preset_name: str, stages: list[str]) -> int:
    """A manually selected stability stage must have work under either preset."""
    if "stability" not in stages:
        return 0
    return max(STABILITY_REQUESTS, int(PRESETS[preset_name]["stability_requests"]))


def validate_context_capacity(
    max_context: int | None,
    performance_cases: list[tuple[str, int]],
    needle_lengths: list[str],
) -> None:
    if max_context is None:
        return
    required = max((tokens + 256 + 64 for _, tokens in performance_cases), default=0)
    for label in needle_lengths:
        tokens = int(float(label.lower().removesuffix("k")) * 1024 * 0.98) if label.lower().endswith("k") else int(label)
        required = max(required, tokens + 200)
    if required > int(max_context):
        raise ValueError(
            f"所选输入长度至少需要 {required:,} tokens 的模型上下文上限（含输出预留），"
            f"当前选择 {int(max_context):,}。请提高模型上下文上限或取消较长输入。"
        )


def eligible_context_cases(
    cap: int | None,
    performance_cases: list[tuple[str, int]],
    needle_lengths: list[str],
) -> tuple[list[tuple[str, int]], list[str], list[dict[str, str]]]:
    """Partition prompt-size cases for one configured cap, with explicit skips."""
    if cap is None:
        return list(performance_cases), list(needle_lengths), []
    perf: list[tuple[str, int]] = []
    needle: list[str] = []
    skipped: list[dict[str, str]] = []
    for label, tokens in performance_cases:
        if tokens + 320 <= cap:
            perf.append((label, tokens))
        else:
            skipped.append({"stage": "performance", "case_id": f"performance-{label}", "reason": "档位不适用：输入与输出预留超过模型上限"})
    for label in needle_lengths:
        target = int(float(label.lower().removesuffix("k")) * 1024 * 0.98) if label.lower().endswith("k") else int(label)
        if target + 200 <= cap:
            needle.append(label)
        else:
            skipped.append({"stage": "needle", "case_id": f"needle-{label}", "reason": "档位不适用：输入与输出预留超过模型上限"})
    if 32768 + 512 > cap:
        skipped.append({"stage": "cache", "case_id": "cache-32k", "reason": "档位不适用：多轮缓存测试需要超过 32K 的空间"})
    return perf, needle, skipped


def resolve_context_cases(
    preset_name: str, selected: list[str] | None, allow_empty: bool = False, preset_policy: bool = False
) -> tuple[list[tuple[str, int]], list[str]]:
    """Return performance and Needle cases for selected context lengths.

    Omitting the selection keeps the historical preset behavior for CLI callers.
    """
    preset = PRESETS[preset_name]
    if selected is None:
        return list(preset["performance"]), list(preset["needle_lengths"])
    normalized = [str(value).strip().lower() for value in selected if str(value).strip()]
    if not normalized:
        if allow_empty:
            return [], []
        raise ValueError("至少选择一个上下文长度。")
    unknown = sorted(set(normalized) - set(CONTEXT_CASES))
    if unknown:
        raise ValueError("未知上下文长度：" + ", ".join(unknown))
    if len(normalized) != len(set(normalized)):
        raise ValueError("上下文长度不能重复选择。")
    performance = [(label, CONTEXT_CASES[label][0]) for label in CONTEXT_CASES if label in normalized]
    needle = ([label for label in PRESETS[preset_name]["needle_lengths"] if label in normalized]
              if preset_policy else [CONTEXT_CASES[label][1] for label in CONTEXT_CASES if label in normalized])
    return performance, needle


def load_context_cases(performance_cases: list[tuple[str, int]], preset_name: str | None = None) -> list[tuple[str, int]]:
    """Keep regular concurrent requests short; stress explicitly selects long inputs."""
    if preset_name is None:
        return list(performance_cases)
    allowed = set(PRESETS[preset_name]["load_lengths"])
    return [(label, tokens) for label, tokens in performance_cases if label in allowed]


def validate_stage_workloads(
    stages: list[str], performance_cases: list[tuple[str, int]], needle_lengths: list[str],
    load_cases: list[tuple[str, int]], tiers: list[int | None],
) -> None:
    unknown = sorted(set(stages) - {"performance", "cache", "agent", "needle", "load", "stability", "capacity"})
    if unknown:
        raise ValueError("未知测试阶段：" + ", ".join(unknown))
    if "performance" in stages and not any(eligible_context_cases(tier, performance_cases, needle_lengths)[0] for tier in tiers):
        raise ValueError("基础性能没有可运行的输入长度；请调整输入或模型上限")
    if "needle" in stages and not any(eligible_context_cases(tier, performance_cases, needle_lengths)[1] for tier in tiers):
        raise ValueError("长上下文召回没有可运行的输入长度；请调整输入或模型上限")
    if "load" in stages and not any(eligible_context_cases(tier, load_cases, [])[0] for tier in tiers):
        raise ValueError("并发性能没有可运行的输入长度；请调整输入或模型上限")
    if "cache" in stages and not any(tier is None or tier > 32768 for tier in tiers):
        raise ValueError("对话缓存需要大于 32K 的模型上限")
    if "capacity" in stages and tiers == [None]:
        raise ValueError("上下文容量探测需要至少选择一个模型上限档位")


def _git_revision(root: Path) -> str | None:
    try:
        cp = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True, timeout=10, creationflags=CREATE_NO_WINDOW
        )
        value = cp.stdout.strip()
        return value if cp.returncode == 0 and value else None
    except (OSError, subprocess.SubprocessError):
        return None


def _engine_version(root: Path) -> str | None:
    """Read the version of the engine this benchmark will launch, not the source checkout."""
    engine_dir = root / "engine"
    try:
        metadata = json.loads((engine_dir / "BUILD.json").read_text(encoding="utf-8"))
        version = str(metadata.get("version") or "").strip()
        if version:
            return version
    except (OSError, ValueError, AttributeError):
        pass

    executable = engine_dir / "strata.exe"
    try:
        result = subprocess.run(
            [str(executable), "--version"],
            cwd=str(root),
            capture_output=True,
            text=True,
            timeout=10,
            creationflags=CREATE_NO_WINDOW,
        )
        label, separator, version = result.stdout.strip().partition(" ")
        if result.returncode == 0 and separator and label.lower() == "strata" and version.strip():
            return version.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def _friendly_cpu_name() -> str | None:
    if platform.system() != "Windows":
        return None
    try:
        import winreg

        key_path = r"HARDWARE\DESCRIPTION\System\CentralProcessor\0"
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path) as key:
            value, _ = winreg.QueryValueEx(key, "ProcessorNameString")
        return str(value).strip() or None
    except (ImportError, OSError):
        return None


def collect_hardware(paths: Any) -> dict[str, Any]:
    cpu_model = _friendly_cpu_name()
    hardware = {
        "captured_at": utc_now(),
        "platform": platform.platform(),
        "windows_version": platform.version(),
        "python": sys.version,
        "cpu": platform.processor() or None,
        "cpu_model": cpu_model,
        "logical_cpu_count": psutil.cpu_count(logical=True),
        "physical_cpu_count": psutil.cpu_count(logical=False),
        "installed_ram_bytes": psutil.virtual_memory().total,
        "gpus": query_nvidia(),
        "strata_git_revision": _git_revision(paths.root),
        "strata_engine_version": _engine_version(paths.root),
        "engine": _file_fact(paths.root / "engine" / "strata.exe"),
    }
    launcher_dir = getattr(paths, "launcher", None)
    if launcher_dir is not None:
        state = read_json(Path(launcher_dir) / "data" / "gpu-power-restore.json", {}) or {}
        records = state.get("records") or []
        if records:
            current = {item["uuid"]: item["watts"] for item in _query_nvidia_power_limits()}
            active = [
                {"uuid": record["uuid"], "watts": current[record["uuid"]], "launcher_target_watts": record["last_applied"]}
                for record in records
                if record.get("uuid") in current
            ]
            if active:
                hardware["gpu_power_limits"] = active
    return hardware


def _query_nvidia_power_limits() -> list[dict[str, Any]]:
    try:
        cp = subprocess.run(
            ["nvidia-smi", "--query-gpu=uuid,power.limit", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10,
            creationflags=CREATE_NO_WINDOW,
        )
        if cp.returncode:
            return []
        result = []
        for line in cp.stdout.splitlines():
            parts = [part.strip() for part in line.split(",")]
            if len(parts) == 2 and parts[0].startswith("GPU-"):
                result.append({"uuid": parts[0], "watts": float(parts[1])})
        return result
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def _with_stage_telemetry(
    server: OwnedServer, run_stage: Callable[[], list[dict[str, Any]]]
) -> list[dict[str, Any]]:
    sample_index = len(server.sampler.samples)
    records = run_stage()
    telemetry = server.sampler.summary(sample_index)
    return [{**record, **telemetry} for record in records]


def _file_fact(path: Path) -> dict[str, Any]:
    try:
        stat = path.stat()
        return {"path": str(path), "size": stat.st_size, "modified": stat.st_mtime}
    except OSError:
        return {"path": str(path), "size": None, "modified": None}


def _resolve_models(root: Path, requested: list[str]) -> list[ModelProfile]:
    profiles = discover_profiles(root)
    if not requested:
        return profiles
    wanted = {str(Path(x).resolve()).lower() for x in requested}
    selected = [p for p in profiles if str(p.config_path).lower() in wanted]
    missing = wanted - {str(p.config_path).lower() for p in selected}
    if missing:
        raise RuntimeError("以下模型配置无效或不存在：" + ", ".join(sorted(missing)))
    if len({p.model_id for p in selected}) != len(selected):
        raise RuntimeError("模型选择包含重复项")
    return selected


def _preflight(paths: Any, profiles: list[ModelProfile], report_root: Path, benchmark_port: int) -> None:
    if not profiles:
        raise RuntimeError("没有找到有效的 strata-*.json 模型配置")
    for required in (paths.python, paths.server, benchmark_tool_path(paths, "needle_bench.py"),
                     benchmark_tool_path(paths, "serve_load.py")):
        if not required.exists():
            raise RuntimeError(f"缺少必需文件：{required}")
    report_root.mkdir(parents=True, exist_ok=True)
    probe = report_root / f".write-probe-{os.getpid()}"
    probe.write_text("ok", encoding="ascii")
    probe.unlink()
    for profile in profiles:
        revalidate_profile(profile)
    ensure_ports_free([benchmark_port] + [p.port for p in profiles])


def _failure_record(run_id: str, profile: ModelProfile, round_number: int, stage: str, exc: BaseException) -> dict[str, Any]:
    return {
        "run_id": run_id,
        "model_id": profile.model_id,
        "model_name": profile.model_name,
        "config_snapshot": None,
        "round": round_number,
        "stage": stage,
        "case_id": f"{stage}-error",
        "status": "failure",
        "error": {"type": type(exc).__name__, "message": str(exc)},
    }


def _run_stage(
    dirs: RunDirectories,
    run_id: str,
    profile: ModelProfile,
    round_number: int,
    stage: str,
    operation: Callable[[], list[dict[str, Any]] | dict[str, Any]],
    record_extra: dict[str, Any] | None = None,
) -> None:
    if is_cancelled(dirs):
        return
    write_status(dirs, state="running", model_id=profile.model_id, round=round_number, stage=stage, message=f"正在运行 {stage}")
    try:
        result = operation()
        rows = result if isinstance(result, list) else [result]
        for row in rows:
            append_record(dirs, {**row, **(record_extra or {})})
    except Exception as exc:
        append_record(dirs, {**_failure_record(run_id, profile, round_number, stage, exc), **(record_extra or {})})


def read_server_status(port: int) -> dict[str, Any]:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/status", timeout=10) as response:
        return json.load(response)


def verify_serving_slots(port: int, expected: int, expected_context: int | None = None) -> int:
    status = read_server_status(port)
    actual = int((status.get("concurrency") or {}).get("serving") or 0)
    if actual != expected:
        raise RuntimeError(f"请求引擎并发 {expected} 槽，实际只有 {actual} 槽；并发结果不可比较。请降低最大并发或模型上限")
    if expected_context is not None:
        actual_context = int((status.get("context") or {}).get("max_positions") or 0)
        if actual_context != expected_context:
            raise RuntimeError(f"请求模型上下文 {expected_context}，服务实际报告 {actual_context}；结果不可比较")
        if (status.get("vision") or {}).get("enabled") is not False:
            raise RuntimeError("统一文本测试无法核验视觉编码器已关闭；结果不可比较")
    return actual


def run_benchmark(args: argparse.Namespace) -> int:
    apply_preset_defaults(args)
    paths = runtime_paths(Path(args.root) if args.root else None)
    report_root = Path(args.report_root).resolve() if args.report_root else paths.reports
    profiles = _resolve_models(paths.root, args.model or [])
    uniform = True
    preset = PRESETS[args.preset]
    stages = [x.strip() for x in (args.stages.split(",") if args.stages else preset["stages"]) if x.strip()]
    try:
        performance_cases, needle_lengths = resolve_context_cases(
            args.preset,
            args.context_lengths.split(",") if args.context_lengths is not None else None,
            allow_empty=not any(stage in {"performance", "needle", "load"} for stage in stages),
            preset_policy=args.preset_policy,
        )
    except ValueError as exc:
        raise RuntimeError(str(exc)) from exc
    try:
        effective_tiers, ignored_tiers, selected_tiers = _selected_tiers_from_args(args)
        for tier in effective_tiers:
            resolve_model_context_overrides(tier)
        load_clients = resolve_load_clients(args.preset, args.max_concurrency) if "load" in stages else []
        if args.context_tiers is None:
            validate_context_capacity(args.max_context, performance_cases, needle_lengths)
    except ValueError as exc:
        raise RuntimeError(str(exc)) from exc
    load_policy = args.preset if args.preset_policy or args.context_lengths is None else None
    selected_load_cases = load_context_cases(performance_cases, load_policy)
    try:
        validate_stage_workloads(stages, performance_cases, needle_lengths, selected_load_cases, effective_tiers)
    except ValueError as exc:
        raise RuntimeError(str(exc)) from exc
    if args.rounds < 1 or args.rounds > 20:
        raise RuntimeError("轮数必须在 1 到 20 之间")
    _preflight(paths, profiles, report_root, args.port)
    if any(is_qwen36_own_path(profile.config) for profile in profiles):
        if any(tier is not None and tier > NATIVE_CONTEXT_LIMIT for tier in effective_tiers):
            raise RuntimeError("Qwen3.6 独立引擎仅支持不超过 256K 的原生上下文；请取消 384K/512K 档")
    common_source_cap = None
    if uniform:
        try:
            if any(tier is None for tier in effective_tiers):
                source_caps = set()
                source_scalings = set()
                for profile in profiles:
                    options = [str(value) for value in profile.config.get("args") or []]
                    if "--max-context" not in options:
                        raise ValueError("原配置缺少模型上限；请在 Benchmark 中选择模型上限档位")
                    source_caps.add(int(options[options.index("--max-context") + 1]))
                    source_scalings.add(tuple(
                        options[options.index(flag) + 1] if flag in options and options.index(flag) + 1 < len(options) else None
                        for flag in ("--rope-scaling", "--rope-scale", "--yarn-orig-ctx")
                    ))
                if len(source_caps) > 1:
                    raise ValueError("原配置的模型上限不同；请在 Benchmark 中选择共同的模型上限档位")
                if len(source_scalings) > 1:
                    raise ValueError("原配置的 YaRN/ROPE 上下文缩放参数不同；请在 Benchmark 中选择共同的模型上限档位")
                common_source_cap = next(iter(source_caps))
                validate_context_capacity(common_source_cap, performance_cases, needle_lengths)
                validate_context_capacity(common_source_cap, selected_load_cases, [])
            validate_uniform_compatibility([
                normalize_uniform_config(profile.config, phase="solo", slots=max(load_clients, default=1))
                for profile in profiles
            ])
        except ValueError as exc:
            raise RuntimeError(str(exc)) from exc
    agent_cases = load_cases(paths.launcher / "benchmark" / "agent_cases.json", args.preset)
    stability_requests = resolve_stability_requests(args.preset, stages)
    variants = build_context_variants(profiles, effective_tiers, legacy_single=args.context_tiers is None)
    matrix_mode = args.context_tiers is not None or "capacity" in stages
    request = {
        "preset": args.preset,
        "preset_label": preset["label"],
        "rounds": args.rounds,
        "benchmark_port": args.port,
        "stages": stages,
        "models": [profile_to_dict(item.profile) for item in variants],
        "context_lengths": [label for label, _ in performance_cases],
        "performance_cases": performance_cases,
        "needle_lengths": needle_lengths,
        "model_max_context": (args.max_context if args.max_context is not None
                              else effective_tiers[0] if args.context_tiers and len(effective_tiers) == 1
                              else "多档" if args.context_tiers else "原配置"),
        "experimental_context_scaling": any(tier is not None and tier > NATIVE_CONTEXT_LIMIT for tier in effective_tiers),
        "max_concurrency": max(load_clients, default=0),
        "load_clients": load_clients,
        "load_input_lengths": [label for label, _ in selected_load_cases],
        "load_prompt_mode": "selected_lengths",
        "load_rounds": preset["load_rounds"],
        "load_max_tokens": LOAD_MAX_TOKENS,
        "load_words": LOAD_WORDS,
        "stability_requests": stability_requests,
        "agent_case_count": len(agent_cases),
        "single_pass_stages": ["needle", "load", "stability"],
    }
    if uniform:
        request["uniform_config"] = True
        request["uniform_phases"] = {"solo": "prompt-cache 0, parallel 1"}
        if "cache" in stages:
            request["uniform_phases"]["cache"] = "prompt-cache 6, parallel 1"
        if "load" in stages:
            request["uniform_phases"]["load"] = f"prompt-cache 0, parallel {max(load_clients, default=1)}"
    if matrix_mode:
        request.update({
            "models": [{**profile_to_dict(item.profile), "source_model_id": item.source_model_id,
                        "context_tier": item.context_tier} for item in variants],
            "selected_context_tiers": selected_tiers,
            "effective_context_tiers": effective_tiers,
            "ignored_context_tiers": ignored_tiers,
            "sweep_context_tiers": bool(args.sweep_context_tiers),
            "single_pass_stages": ["needle", "load", "stability", "capacity"],
        })
    dirs = create_run_directories(report_root, args.preset, request)
    if args.pointer:
        atomic_json(Path(args.pointer), {"run_dir": str(dirs.root), "controller_pid": os.getpid(), "created_at": utc_now()})
    manifest = read_json(dirs.manifest, {}) or {}
    run_id = str(manifest.get("run_id"))
    atomic_json(dirs.hardware, collect_hardware(paths))
    update_manifest(dirs, state="running", started_at=utc_now(), controller_pid=os.getpid())
    write_status(dirs, state="running", total_rounds=args.rounds, current=0, message="Benchmark 已开始")
    fatal_error: str | None = None
    completed_sessions = 0
    total_sessions = args.rounds * len(variants)
    startup_failed: dict[str, int] = {}
    try:
        for round_index in range(1, args.rounds + 1):
            order = variants if round_index % 2 == 1 else list(reversed(variants))
            for variant in order:
                profile = variant.profile
                tier = variant.context_tier
                if is_cancelled(dirs):
                    break
                metadata = {"source_model_id": variant.source_model_id, "context_tier": tier} if matrix_mode else {}
                if tier is not None and variant.source_model_id in startup_failed and tier > startup_failed[variant.source_model_id]:
                    append_record(dirs, {"run_id": run_id, "model_id": profile.model_id, "model_name": profile.model_name,
                                         "round": round_index, "stage": "startup", "case_id": "resource-guard",
                                         "status": "skipped", "reason": "低档启动失败；更高档未执行（安全保护）", **metadata})
                    completed_sessions += 1
                    continue
                tier_performance, tier_needle, inapplicable = eligible_context_cases(tier, performance_cases, needle_lengths)
                tier_load_cases = load_context_cases(tier_performance, load_policy)
                for skipped in inapplicable:
                    if skipped["stage"] in stages and (round_index == 1 or skipped["stage"] != "needle"):
                        append_record(dirs, {"run_id": run_id, "model_id": profile.model_id,
                                             "model_name": profile.model_name, "round": round_index,
                                             "status": "skipped", **skipped, **metadata})
                    if skipped["stage"] == "performance" and "load" in stages and round_index == 1:
                        label = skipped["case_id"].removeprefix("performance-")
                        if label in {name for name, _ in selected_load_cases}:
                            for count in load_clients:
                                append_record(dirs, {"run_id": run_id, "model_id": profile.model_id,
                                                     "model_name": profile.model_name, "round": round_index,
                                                     "stage": "load", "case_id": f"load-{label}-clients-{count}",
                                                     "input_length": label, "clients": count,
                                                     "status": "skipped", "reason": skipped["reason"], **metadata})
                server: OwnedServer | None = None
                snapshot = None
                active_phase = "startup"
                write_status(
                    dirs,
                    state="loading",
                    model_id=profile.model_id,
                    round=round_index,
                    current=completed_sessions,
                    total=total_sessions,
                    message=f"正在启动 {profile.model_name} ({tier // 1024}K)" if tier else f"正在启动 {profile.model_name}",
                )
                try:
                    if uniform:
                        snapshot = snapshot_profile(profile, dirs.configs, args.port, round_index,
                                                    resolve_model_context_overrides(tier),
                                                    uniform_phase="solo", uniform_slots=max(load_clients, default=1))
                    else:
                        snapshot = snapshot_profile(profile, dirs.configs, args.port, round_index,
                                                    resolve_model_context_overrides(tier))
                    server = start_server(snapshot, paths, dirs, round_index)
                    effective_slots = verify_serving_slots(args.port, 1, tier or common_source_cap) if uniform else None
                    append_record(
                        dirs,
                        {
                            "run_id": run_id,
                            "model_id": profile.model_id,
                            "model_name": profile.model_name,
                            "config_snapshot": str(snapshot.path),
                            "round": round_index,
                            "stage": "startup",
                            "case_id": "cold-start",
                            "status": "success",
                            "load_seconds": server.load_seconds,
                            **({"serving_slots": effective_slots} if uniform else {}),
                            **metadata,
                            **server.sampler.summary(0),
                        },
                    )
                    client = StrataClient(args.port)
                    _run_stage(
                        dirs,
                        run_id,
                        profile,
                        round_index,
                        "warmup",
                        lambda: {
                            "run_id": run_id,
                            "model_id": profile.model_id,
                            "model_name": profile.model_name,
                            "config_snapshot": str(snapshot.path),
                            "round": round_index,
                            "stage": "warmup",
                            "case_id": "short",
                            **warm_up(client),
                        },
                        metadata,
                    )
                    if "performance" in stages:
                        for label, target in tier_performance:
                            case = PerformanceCase(f"performance-{label}", label, int(target))
                            _run_stage(
                                dirs,
                                run_id,
                                profile,
                                round_index,
                                "performance",
                                lambda c=case: run_performance(client, server, dirs, paths.root, c, round_index, 1, run_id),
                                metadata,
                            )
                    if not uniform and "cache" in stages and (tier is None or tier > 32768):
                        _run_stage(
                            dirs,
                            run_id,
                            profile,
                            round_index,
                            "cache",
                            lambda: run_cache_sequence(client, server, dirs, paths.root, CacheCase(), round_index, run_id),
                            metadata,
                        )
                    if "agent" in stages:
                        for case in agent_cases:
                            _run_stage(
                                dirs,
                                run_id,
                                profile,
                                round_index,
                                "agent",
                                lambda c=case: run_agent_case(client, server, dirs, c, round_index, run_id),
                                metadata,
                            )
                    # Correctness/load stages are single-pass; the repeated rounds target performance variance.
                    if round_index == 1 and "needle" in stages and tier_needle:
                        _run_stage(
                            dirs,
                            run_id,
                            profile,
                            round_index,
                            "needle",
                            lambda: _with_stage_telemetry(
                                server,
                                lambda: run_needle(server, paths, dirs, round_index, run_id, list(tier_needle)),
                            ),
                            metadata,
                        )
                    if round_index == 1 and "capacity" in stages and tier is not None:
                        _run_stage(
                            dirs, run_id, profile, round_index, "capacity",
                            lambda: run_capacity_probe(client, server, dirs, paths.root, round_index, run_id, tier),
                            metadata,
                        )
                    if not uniform and round_index == 1 and "load" in stages and tier_load_cases:
                        _run_stage(
                            dirs,
                            run_id,
                            profile,
                            round_index,
                            "load",
                            lambda: _with_stage_telemetry(
                                server,
                                lambda: run_load(server, paths, dirs, round_index, run_id, load_clients,
                                                  rounds=preset["load_rounds"], context_cases=tier_load_cases),
                            ),
                            metadata,
                        )
                    if round_index == 1 and "stability" in stages:
                        _run_stage(
                            dirs,
                            run_id,
                            profile,
                            round_index,
                            "stability",
                            lambda: run_stability(
                                client, server, dirs, round_index, run_id, stability_requests
                            ),
                            metadata,
                        )
                    if uniform:
                        phase_order = []
                        if "cache" in stages and (tier is None or tier > 32768):
                            phase_order.append("cache")
                        if round_index == 1 and "load" in stages and tier_load_cases:
                            phase_order.append("load")
                        for phase in phase_order:
                            if is_cancelled(dirs):
                                break
                            active_phase = phase
                            stop_result = stop_server(server)
                            server = None
                            if stop_result.manual_cleanup_required:
                                fatal_error = "无法验证并安全结束本次 Server：" + stop_result.detail
                                raise RuntimeError(fatal_error)
                            snapshot = snapshot_profile(profile, dirs.configs, args.port, round_index,
                                                        resolve_model_context_overrides(tier),
                                                        uniform_phase=phase, uniform_slots=max(load_clients, default=1))
                            server = start_server(snapshot, paths, dirs, round_index)
                            effective_slots = verify_serving_slots(
                                args.port, max(load_clients, default=1) if phase == "load" else 1, tier or common_source_cap
                            )
                            append_record(dirs, {"run_id": run_id, "model_id": profile.model_id,
                                                 "model_name": profile.model_name, "config_snapshot": str(snapshot.path),
                                                 "round": round_index, "stage": "startup", "case_id": f"cold-start-{phase}",
                                                 "status": "success", "load_seconds": server.load_seconds,
                                                 "serving_slots": effective_slots,
                                                 **metadata, **server.sampler.summary(0)})
                            client = StrataClient(args.port)
                            _run_stage(dirs, run_id, profile, round_index, "warmup",
                                       lambda: {"run_id": run_id, "model_id": profile.model_id,
                                                "model_name": profile.model_name, "config_snapshot": str(snapshot.path),
                                                "round": round_index, "stage": "warmup", "case_id": f"short-{phase}",
                                                **warm_up(client)}, metadata)
                            if phase == "cache":
                                _run_stage(dirs, run_id, profile, round_index, "cache",
                                           lambda: run_cache_sequence(client, server, dirs, paths.root,
                                                                      CacheCase(), round_index, run_id), metadata)
                            else:
                                def checked_load() -> list[dict[str, Any]]:
                                    actual_slots = verify_serving_slots(args.port, max(load_clients, default=1), tier or common_source_cap)
                                    rows = _with_stage_telemetry(
                                         server, lambda: run_load(server, paths, dirs, round_index, run_id, load_clients,
                                                                  rounds=preset["load_rounds"], context_cases=tier_load_cases)
                                    )
                                    return [{**row, "serving_slots": actual_slots} for row in rows]
                                _run_stage(dirs, run_id, profile, round_index, "load", checked_load, metadata)
                except Exception as exc:
                    append_record(dirs, {**_failure_record(run_id, profile, round_index, active_phase, exc), **metadata})
                    if active_phase == "startup" and server is None and tier is not None:
                        startup_failed[variant.source_model_id] = tier
                finally:
                    if server:
                        stop_result = stop_server(server)
                        if stop_result.manual_cleanup_required:
                            fatal_error = "无法验证并安全结束本次 Server：" + stop_result.detail
                            append_record(
                                dirs,
                                {
                                    "run_id": run_id,
                                    "model_id": profile.model_id,
                                    "model_name": profile.model_name,
                                    "config_snapshot": str(snapshot.path) if snapshot else None,
                                    "round": round_index,
                                    "stage": "shutdown",
                                    "case_id": "safe-stop",
                                    "status": "failure",
                                    "error": fatal_error,
                                },
                            )
                    completed_sessions += 1
                    write_status(dirs, current=completed_sessions, total=total_sessions)
                if fatal_error:
                    break
            if is_cancelled(dirs) or fatal_error:
                break
    except Exception as exc:
        fatal_error = f"{type(exc).__name__}: {exc}"
        update_manifest(dirs, fatal_traceback=traceback.format_exc())
    finally:
        if is_cancelled(dirs):
            final_state = "cancelled"
        elif fatal_error:
            final_state = "failed"
        else:
            records, parse_errors = read_records(dirs.records)
            completion = assess_completion(request, records, parse_errors)
            final_state = completion["state"]
            update_manifest(dirs, completion=completion)
        update_manifest(dirs, state=final_state, ended_at=utc_now(), fatal_error=fatal_error)
        write_status(dirs, state=final_state, message={"completed": "测试完成", "partial": "测试部分完成：请查看未执行或失败阶段", "cancelled": "测试已安全停止", "failed": "测试失败"}[final_state])
        try:
            render_reports(dirs.root)
        except Exception as exc:
            update_manifest(dirs, report_error=f"{type(exc).__name__}: {exc}")
    print(str(dirs.root))
    return 0 if final_state == "completed" else 1


def command_list(args: argparse.Namespace) -> int:
    paths = runtime_paths(Path(args.root) if args.root else None)
    print(json.dumps([profile_to_dict(p) for p in discover_profiles(paths.root)], ensure_ascii=False, indent=2))
    return 0


def command_presets(args: argparse.Namespace) -> int:
    print(json.dumps(PRESETS, ensure_ascii=False))
    return 0


def command_cancel(args: argparse.Namespace) -> int:
    dirs = open_existing_run(Path(args.run_dir))
    request_cancel(dirs, os.getpid())
    print(json.dumps({"ok": True, "run_dir": str(dirs.root)}, ensure_ascii=False))
    return 0


def command_status(args: argparse.Namespace) -> int:
    dirs = open_existing_run(Path(args.run_dir))
    print(json.dumps(read_json(dirs.status, {}), ensure_ascii=False, indent=2))
    return 0


def command_render(args: argparse.Namespace) -> int:
    paths = render_reports(Path(args.run_dir).resolve())
    print(json.dumps(paths, ensure_ascii=False, indent=2))
    return 0


def command_estimate(args: argparse.Namespace) -> int:
    apply_preset_defaults(args)
    preset = PRESETS[args.preset]
    stages = [x.strip() for x in (args.stages.split(",") if args.stages else preset["stages"]) if x.strip()]
    try:
        performance_cases, needle_lengths = resolve_context_cases(
            args.preset,
            args.context_lengths.split(",") if args.context_lengths is not None else None,
            allow_empty=not any(stage in {"performance", "needle", "load"} for stage in stages),
            preset_policy=args.preset_policy,
        )
    except ValueError as exc:
        raise RuntimeError(str(exc)) from exc
    try:
        tiers, ignored_tiers, selected_tiers = _selected_tiers_from_args(args)
        for tier in tiers:
            resolve_model_context_overrides(tier)
        load_clients = resolve_load_clients(args.preset, args.max_concurrency) if "load" in stages else []
        if args.context_tiers is None:
            validate_context_capacity(args.max_context, performance_cases, needle_lengths)
    except ValueError as exc:
        raise RuntimeError(str(exc)) from exc
    models = max(1, len(args.model or []))
    load_policy = args.preset if args.preset_policy or args.context_lengths is None else None
    selected_load_cases = load_context_cases(performance_cases, load_policy)
    try:
        validate_stage_workloads(stages, performance_cases, needle_lengths, selected_load_cases, tiers)
    except ValueError as exc:
        raise RuntimeError(str(exc)) from exc
    if args.rounds < 1 or args.rounds > 20:
        raise RuntimeError("轮数必须在 1 到 20 之间")
    tier_load_counts = [len(load_context_cases(
        eligible_context_cases(tier, performance_cases, needle_lengths)[0], load_policy
    )) for tier in tiers]
    planned_server_starts = models * sum(
        args.rounds
        + (args.rounds if "cache" in stages and (tier is None or tier > 32768) else 0)
        + (1 if "load" in stages and load_count else 0)
        for tier, load_count in zip(tiers, tier_load_counts)
    )
    result = {
        "preset": args.preset,
        "preset_label": preset["label"],
        "stages": stages,
        "models": models,
        "rounds": args.rounds,
        "model_sessions": models * args.rounds * len(tiers),
        "planned_server_starts": planned_server_starts,
        "selected_context_tiers": selected_tiers,
        "effective_context_tiers": tiers,
        "ignored_context_tiers": ignored_tiers,
        "context_lengths": [label for label, _ in performance_cases],
        "model_max_context": (args.max_context if args.max_context is not None else
                              tiers[0] if len(tiers) == 1 and tiers[0] is not None else
                              "原配置" if tiers == [None] else "多档"),
        "max_concurrency": max(load_clients, default=0),
        "load_clients": load_clients,
        "performance_requests": models * args.rounds * sum(len(eligible_context_cases(tier, performance_cases, needle_lengths)[0]) for tier in tiers) if "performance" in stages else 0,
        "cache_requests": models * args.rounds * 3 * sum(tier is None or tier > 32768 for tier in tiers) if "cache" in stages else 0,
        "agent_requests": models * args.rounds * len(tiers) * len(load_cases(runtime_paths().launcher / "benchmark" / "agent_cases.json", args.preset)) if "agent" in stages else 0,
        "needle_requests": models * sum(len(eligible_context_cases(tier, performance_cases, needle_lengths)[1]) for tier in tiers) * 3 if "needle" in stages else 0,
        "capacity_requests": models * len(tiers) * 6 if "capacity" in stages else 0,
        "stability_requests": models * len(tiers) * resolve_stability_requests(args.preset, stages) if "stability" in stages else 0,
        "load_input_lengths": [label for label, _ in selected_load_cases],
        "load_prompt_mode": "selected_lengths",
        "load_bursts": models * sum(tier_load_counts) * len(load_clients) * preset["load_rounds"] if "load" in stages else 0,
        "load_rounds": preset["load_rounds"],
        "load_max_tokens": LOAD_MAX_TOKENS,
        "load_words": LOAD_WORDS,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Strata launcher batch benchmark")
    sub = parser.add_subparsers(dest="command", required=True)
    listed = sub.add_parser("list-models")
    listed.add_argument("--root")
    listed.set_defaults(func=command_list)
    presets = sub.add_parser("list-presets")
    presets.set_defaults(func=command_presets)
    run = sub.add_parser("run")
    run.add_argument("--root")
    run.add_argument("--model", action="append")
    run.add_argument("--preset", choices=sorted([*PRESETS, "stress"]), default="standard")
    run.add_argument("--rounds", type=int)
    run.add_argument("--context-lengths", help="comma-separated context sizes: 1k,4k,32k,128k,256k")
    run.add_argument("--preset-policy", action="store_true", help="limit recall and concurrent lengths to the selected preset")
    run.add_argument("--max-context", type=int, choices=MODEL_CONTEXT_CHOICES, help="temporary model config context cap; >256K enables experimental YaRN scaling")
    run.add_argument("--source-context", action="store_true", help="use the source model context cap when all selected models match")
    run.add_argument("--context-tiers", help="comma-separated model context caps to select")
    run.add_argument("--sweep-context-tiers", action="store_true", help="run each selected cap independently")
    run.add_argument("--max-concurrency", type=int, choices=range(1, 5), help="test client concurrency from 1 through this maximum")
    run.add_argument("--uniform-config", action="store_true", default=True, help="legacy alias; controlled snapshots are now always used")
    run.add_argument("--port", type=int, default=8188)
    run.add_argument("--stages", help="comma-separated stage names")
    run.add_argument("--report-root")
    run.add_argument("--pointer", help="write current run directory and controller PID to this JSON file")
    run.set_defaults(func=run_benchmark)
    cancel = sub.add_parser("cancel")
    cancel.add_argument("--run-dir", required=True)
    cancel.set_defaults(func=command_cancel)
    status = sub.add_parser("status")
    status.add_argument("--run-dir", required=True)
    status.set_defaults(func=command_status)
    render = sub.add_parser("render")
    render.add_argument("--run-dir", required=True)
    render.set_defaults(func=command_render)
    estimate = sub.add_parser("estimate")
    estimate.add_argument("--preset", choices=sorted([*PRESETS, "stress"]), default="standard")
    estimate.add_argument("--rounds", type=int)
    estimate.add_argument("--context-lengths", help="comma-separated context sizes: 1k,4k,32k,128k,256k")
    estimate.add_argument("--preset-policy", action="store_true")
    estimate.add_argument("--max-context", type=int, choices=MODEL_CONTEXT_CHOICES)
    estimate.add_argument("--source-context", action="store_true")
    estimate.add_argument("--context-tiers", help="comma-separated model context caps to select")
    estimate.add_argument("--sweep-context-tiers", action="store_true")
    estimate.add_argument("--max-concurrency", type=int, choices=range(1, 5))
    estimate.add_argument("--stages", help="comma-separated stage names")
    estimate.add_argument("--model", action="append")
    estimate.set_defaults(func=command_estimate)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:
        print(f"ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

