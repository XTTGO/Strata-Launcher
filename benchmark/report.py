from __future__ import annotations

import html
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

from .capacity import judge_capacity
from .share_image import export_controls_and_script, render_share_svg
from .storage import atomic_json, read_json, utc_now


STAGE_STATUS_LABELS = {
    "completed": "已完成",
    "failed": "失败",
    "partial": "部分完成",
    "not_run": "未执行",
    "not_selected": "未选择",
    "skipped": "已跳过",
    "cancelled": "已取消",
    "running": "运行中",
    "preparing": "准备中",
}


def _expected_stage_records(request: dict[str, Any], stage: str, stage_rows: list[dict[str, Any]] | None = None) -> int | None:
    rounds = int(request.get("rounds") or 1)
    inapplicable = [row for row in (stage_rows or []) if row.get("status") == "skipped"
                  and str(row.get("reason") or "").startswith("档位不适用")]
    if stage in {"startup", "warmup"}:
        return rounds
    if stage == "performance":
        cases = request.get("performance_cases") or request.get("context_lengths") or []
        return rounds * len(cases)
    if stage == "cache":
        return rounds * 3 - 2 * len(inapplicable)
    if stage == "agent" and isinstance(request.get("agent_case_count"), int):
        return rounds * request["agent_case_count"]
    if stage == "needle":
        lengths = request.get("needle_lengths") or []
        return len(lengths) * 3 - 2 * len(inapplicable)
    if stage == "capacity":
        return 6
    if stage == "load":
        clients = request.get("load_clients") or []
        lengths = request.get("load_input_lengths") or []
        return len(clients) * (len(lengths) if request.get("load_prompt_mode") == "selected_lengths" else 1)
    if stage == "stability":
        if isinstance(request.get("stability_requests"), int):
            return int(request["stability_requests"])
        if request.get("preset") == "full":
            return 10
        return None
    return None


def assess_completion(request: dict[str, Any], records: list[dict[str, Any]], parse_errors: list[str] | None = None) -> dict[str, Any]:
    requested_stages = list(dict.fromkeys(["startup", "warmup", *(request.get("stages") or [])]))
    model_specs = {
        str(model.get("model_id")): model
        for model in request.get("models", [])
        if model.get("model_id")
    }
    for row in records:
        model_id = str(row.get("model_id") or "unknown")
        model_specs.setdefault(model_id, {"model_id": model_id, "model_name": row.get("model_name") or model_id})

    models: dict[str, dict[str, Any]] = {}
    incomplete = False
    failed_records = sum(row.get("status") == "failure" for row in records)
    for model_id, spec in sorted(model_specs.items()):
        model_rows = [row for row in records if str(row.get("model_id") or "unknown") == model_id]
        stages: dict[str, dict[str, Any]] = {}
        for stage in requested_stages:
            stage_rows = [row for row in model_rows if row.get("stage") == stage]
            expected = _expected_stage_records(request, stage, stage_rows)
            successes = sum(row.get("status") == "success" for row in stage_rows)
            failures = sum(row.get("status") == "failure" for row in stage_rows)
            skipped = sum(row.get("status") == "skipped" for row in stage_rows)
            inapplicable = [row for row in stage_rows if row.get("status") == "skipped"
                          and str(row.get("reason") or "").startswith("档位不适用")]
            if not stage_rows:
                state = "not_run"
            elif failures:
                state = "partial" if successes or skipped else "failed"
            elif skipped and skipped == len(inapplicable) and (expected is None or len(stage_rows) >= expected):
                state = "completed"
            elif skipped:
                state = "partial" if successes else "skipped"
            elif expected is not None and len(stage_rows) < expected:
                state = "partial" if successes else "not_run"
            elif successes:
                state = "completed"
            elif stage == "capacity" and stage_rows:
                state = "partial"
            else:
                state = "not_run"
            if stage == "capacity" and state == "completed":
                cap = spec.get("context_tier")
                if not isinstance(cap, int) or judge_capacity(stage_rows, cap)["status"] != "verified":
                    state = "partial"
            if state != "completed":
                incomplete = True
            stages[stage] = {
                "state": state,
                "requested": True,
                "records": len(stage_rows),
                "expected": expected,
                "successes": successes,
                "failures": failures,
                "skipped": skipped,
            }
        models[model_id] = {
            "model_name": spec.get("model_name") or model_id,
            "stages": stages,
        }
    has_parse_errors = bool(parse_errors)
    return {
        "state": "partial" if incomplete or failed_records or has_parse_errors else "completed",
        "failed_records": failed_records,
        "parse_errors": len(parse_errors or []),
        "models": models,
    }


def read_records(path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    records: list[dict[str, Any]] = []
    errors: list[str] = []
    if not path.exists():
        return records, errors
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                records.append(value)
            else:
                errors.append(f"line {number}: JSON root is not object")
        except json.JSONDecodeError as exc:
            errors.append(f"line {number}: {exc}")
    return records, errors


def _numbers(rows: list[dict[str, Any]], key: str) -> list[float]:
    values = []
    for row in rows:
        value = row.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value)):
            values.append(float(value))
    return values


def _prefill_numbers(rows: list[dict[str, Any]]) -> list[float]:
    """Read current engine prefill timing and legacy records named ttft_seconds."""
    return _numbers([{"prefill_seconds": row.get("prefill_seconds", row.get("ttft_seconds"))}
                     for row in rows], "prefill_seconds")


def _stats(values: list[float]) -> dict[str, Any]:
    if not values:
        return {"n": 0, "median": None, "min": None, "max": None}
    return {
        "n": len(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
    }


def _memory_metrics(rows: list[dict[str, Any]], installed_ram_bytes: int) -> dict[str, Any]:
    sampled = [
        row
        for row in rows
        if row.get("sample_count") is None
        or (
            isinstance(row.get("sample_count"), (int, float))
            and not isinstance(row.get("sample_count"), bool)
            and row["sample_count"] > 0
        )
    ]
    sampled = [
        row
        for row in sampled
        if any(key in row for key in ("system_used_peak_bytes", "rss_peak_bytes", "gpu_memory_peak_mib"))
    ]
    system_ram_peaks = _numbers(sampled, "system_used_peak_bytes")
    return {
        "sampled_records": len(sampled),
        "vram_peak_mib": _stats(_numbers(sampled, "gpu_memory_peak_mib")),
        "rss_peak_gib": _stats([v / (1024**3) for v in _numbers(sampled, "rss_peak_bytes")]),
        "system_ram_peak_gib": _stats([v / (1024**3) for v in system_ram_peaks]),
        "system_ram_peak_percent": _stats(
            [v / installed_ram_bytes * 100 for v in system_ram_peaks]
            if installed_ram_bytes > 0
            else []
        ),
    }


def _effective_model_context(run_dir: Path, model_id: str, request: dict[str, Any]) -> int | None:
    spec = _model_config_specs(request).get(model_id) or {}
    if isinstance(spec.get("context_tier"), int) and spec["context_tier"] > 0:
        return spec["context_tier"]
    requested = request.get("model_max_context")
    if isinstance(requested, int) and requested > 0:
        return requested
    if isinstance(requested, str) and requested.strip().isdigit():
        return int(requested.strip())

    # Older manifests say "原配置". Read the immutable run snapshot, never a live model config.
    if Path(model_id).name != model_id:
        return None
    snapshot = read_json(run_dir / "configs" / f"{model_id}-round-1.json", {}) or {}
    args = snapshot.get("args") or []
    if not isinstance(args, list):
        return None
    for option in ("--max-context", "--ctx-size"):
        try:
            value = args[args.index(option) + 1]
            parsed = int(value)
        except (ValueError, IndexError, TypeError):
            continue
        if parsed > 0:
            return parsed
    return None


def _model_config_specs(request: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(spec.get("model_id")): spec
        for spec in request.get("models", [])
        if isinstance(spec, dict) and spec.get("model_id")
    }


def build_summary(run_dir: Path) -> dict[str, Any]:
    manifest = read_json(run_dir / "run-manifest.json", {}) or {}
    hardware = read_json(run_dir / "hardware.json", {}) or {}
    records, parse_errors = read_records(run_dir / "raw-results.jsonl")
    by_model: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in records:
        by_model[str(row.get("model_id") or "unknown")].append(row)
    completion = assess_completion(manifest.get("request") or {}, records, parse_errors)
    request = manifest.get("request") or {}
    config_specs = _model_config_specs(request)
    models: dict[str, Any] = {}
    highest_verified_context: dict[str, int] = {}
    installed_ram_bytes = int(hardware.get("installed_ram_bytes") or 0)
    for model_id, completion_model in completion["models"].items():
        rows = by_model.get(model_id, [])
        success = [r for r in rows if r.get("status") == "success" and not r.get("excluded_from_summary")]
        perf: dict[str, Any] = {}
        for case_id in sorted({str(r.get("case_id")) for r in success if r.get("stage") == "performance"}):
            group = [r for r in success if r.get("stage") == "performance" and str(r.get("case_id")) == case_id]
            perf[case_id] = {
                "record_ids": [r.get("record_id") for r in group],
                "prompt_tps": _stats(_numbers(group, "prompt_tokens_per_second")),
                "decode_tps": _stats(_numbers(group, "decode_tokens_per_second")),
                "prefill_seconds": _stats(_prefill_numbers(group)),
                "wall_seconds": _stats(_numbers(group, "wall_seconds")),
                **_memory_metrics(group, installed_ram_bytes),
            }
        memory_by_stage: dict[str, Any] = {}
        stages = sorted({str(row.get("stage") or "unknown") for row in rows})
        stage_labels = {
            "startup": "模型启动",
            "warmup": "启动预热",
            "cache": "对话缓存",
            "agent": "Agent 能力",
            "needle": "长上下文召回",
            "load": "并发负载（全部并发档）",
            "stability": "稳定性",
        }
        for stage in stages:
            stage_rows = [row for row in rows if str(row.get("stage") or "unknown") == stage]
            if stage == "performance":
                for case_id in sorted({str(row.get("case_id") or "unknown") for row in stage_rows}):
                    case_rows = [row for row in stage_rows if str(row.get("case_id") or "unknown") == case_id]
                    metrics = _memory_metrics(case_rows, installed_ram_bytes)
                    if metrics["sampled_records"]:
                        memory_by_stage[f"performance:{case_id}"] = {
                            "label": f"性能测试 · {case_id.removeprefix('performance-').upper()}",
                            **metrics,
                        }
            else:
                metrics = _memory_metrics(stage_rows, installed_ram_bytes)
                if metrics["sampled_records"]:
                    memory_by_stage[stage] = {
                        "label": stage_labels.get(stage, stage),
                        **metrics,
                    }
        agent_rows = [r for r in success if r.get("stage") == "agent"]
        needle_rows = [r for r in rows if r.get("stage") == "needle" and "found" in r]
        needle_coverage = completion_model["stages"].get("needle") or {}
        needle_expected = needle_coverage.get("expected")
        needle_inapplicable = sum(
            r.get("stage") == "needle" and r.get("status") == "skipped"
            and str(r.get("reason") or "").startswith("档位不适用") for r in rows
        )
        needle_cases = (max(len(needle_rows), needle_expected - needle_inapplicable)
                        if isinstance(needle_expected, int) else len(needle_rows))
        needle_hits = sum(r.get("status") == "success" and r.get("found") is True for r in needle_rows)
        load_rows = [r for r in rows if r.get("stage") == "load"]
        cache_rows = [r for r in success if r.get("stage") == "cache"]
        stability_rows = [r for r in rows if r.get("stage") == "stability"]
        spec = config_specs.get(model_id, {})
        context_tier = spec.get("context_tier")
        capacity_rows = [r for r in rows if r.get("stage") == "capacity"]
        capacity = judge_capacity(capacity_rows, context_tier) if capacity_rows and isinstance(context_tier, int) else None
        source_model_id = str(spec.get("source_model_id") or model_id)
        if capacity and capacity["passed"]:
            highest_verified_context[source_model_id] = max(highest_verified_context.get(source_model_id, 0), context_tier)
        models[model_id] = {
            "model_name": str(next((r.get("model_name") for r in rows if r.get("model_name")), completion_model["model_name"]))
                          + (f" · {context_tier // 1024}K" if isinstance(context_tier, int) and spec.get("source_model_id") else ""),
            "source_model_id": source_model_id,
            "context_tier": context_tier,
            "capacity": capacity,
            "config_hash": config_specs.get(model_id, {}).get("config_hash"),
            "effective_max_context": _effective_model_context(run_dir, model_id, request),
            "records": len(rows),
            "successes": sum(r.get("status") == "success" for r in rows),
            "failures": sum(r.get("status") == "failure" for r in rows),
            "skipped": sum(r.get("status") == "skipped" for r in rows),
            "startup_seconds": _stats(_numbers([r for r in success if r.get("stage") == "startup"], "load_seconds")),
            "performance": perf,
            "memory_by_stage": memory_by_stage,
            "cache": {
                "records": len(cache_rows),
                "prefill_seconds": _stats(_prefill_numbers(cache_rows)),
                "reused_tokens": _stats(_numbers(cache_rows, "reused_prompt_tokens")),
            },
            "agent": {
                "cases": len(agent_rows),
                "passed": sum(bool(r.get("passed")) for r in agent_rows),
                "pass_rate": (sum(bool(r.get("passed")) for r in agent_rows) / len(agent_rows)) if agent_rows else None,
                "record_ids": [r.get("record_id") for r in agent_rows],
            },
            "needle": {
                "cases": needle_cases,
                "found": needle_hits,
                "recall_rate": needle_hits / needle_cases if needle_cases else None,
                "record_ids": [r.get("record_id") for r in needle_rows],
            },
            "load": load_rows,
            "stability": {
                "requests": len(stability_rows),
                "successes": sum(r.get("status") == "success" for r in stability_rows),
                "decode_tps": _stats(_numbers([r for r in stability_rows if r.get("status") == "success"], "decode_tokens_per_second")),
                "wall_seconds": _stats(_numbers([r for r in stability_rows if r.get("status") == "success"], "wall_seconds")),
            },
            "stage_coverage": completion_model["stages"],
            "errors": [r for r in rows if r.get("status") == "failure"],
        }
    return {
        "schema_version": 1,
        "generated_at": utc_now(),
        "manifest": manifest,
        "hardware": hardware,
        "record_count": len(records),
        "record_parse_errors": parse_errors,
        "completion": completion,
        "models": models,
        "highest_verified_context": highest_verified_context,
    }


def _fmt(value: Any, digits: int = 2) -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def _fmt_percent(value: Any) -> str:
    return "—" if value is None else f"{float(value):.2f}%"


def _power_limit_label(hardware: dict[str, Any]) -> str:
    return " / ".join(
        f"{item['uuid']} · {_fmt(item['watts'], 0)} W"
        for item in hardware.get("gpu_power_limits") or []
    )


def _stage_result_text(stage_status: dict[str, Any] | None) -> str:
    if not stage_status:
        return "未选择"
    state = str(stage_status.get("state") or "not_run")
    label = STAGE_STATUS_LABELS.get(state, state)
    successes = int(stage_status.get("successes") or 0)
    expected = stage_status.get("expected")
    if state == "completed" and expected:
        return f"{successes}/{expected}"
    if state == "partial" and expected:
        return f"部分完成 {successes}/{expected}"
    if state == "failed" and expected:
        return f"失败 0/{expected}"
    return label


def _reported_stage_metric(model: dict[str, Any], stage: str, value: int, count: int) -> str:
    coverage = model.get("stage_coverage", {}).get(stage)
    if not coverage:
        return "未选择"
    state = coverage.get("state")
    if state == "not_run":
        return "未执行"
    if state == "failed":
        return "失败"
    ratio = f"{value}/{count}"
    return f"部分完成 {ratio}" if state == "partial" else ratio


def _effective_run_state(summary: dict[str, Any]) -> str:
    manifest_state = str((summary.get("manifest") or {}).get("state", "unknown"))
    completion_state = str((summary.get("completion") or {}).get("state", manifest_state))
    return "partial" if manifest_state == "completed" and completion_state == "partial" else manifest_state


def _selected_stages(summary: dict[str, Any]) -> set[str]:
    request = ((summary.get("manifest") or {}).get("request") or {})
    if isinstance(request.get("stages"), list):
        return set(request["stages"])
    models = (summary.get("models") or {}).values()
    return {stage for model in models for stage in (model.get("stage_coverage") or {})
            if stage not in {"startup", "warmup"}} or {
        stage for model in (summary.get("models") or {}).values()
        for stage in ("performance", "cache", "agent", "needle", "capacity", "load", "stability")
        if model.get(stage)
    }


def _capacity_table_html(summary: dict[str, Any]) -> str:
    if "capacity" not in _selected_stages(summary):
        return ""
    models = summary.get("models") or {}
    if not any(model.get("context_tier") for model in models.values()):
        return ""
    rows = []
    highest = summary.get("highest_verified_context") or {}
    for model_id, model in models.items():
        cap = model.get("context_tier")
        if not isinstance(cap, int):
            continue
        result = model.get("capacity") or {}
        state = {"verified": "已验证可用", "failed": "召回未通过", "insufficient": "证据不足"}.get(result.get("status"), "未执行")
        token_min, token_max = result.get("actual_prompt_tokens_min"), result.get("actual_prompt_tokens_max")
        actual = f"{token_min:,}–{token_max:,}" if isinstance(token_min, int) and isinstance(token_max, int) else "—"
        reasons = "；".join(str(value) for value in result.get("reasons") or []) or "—"
        peak = ((model.get("memory_by_stage") or {}).get("capacity") or {}).get("vram_peak_mib") or {}
        rows.append(
            f"<tr><th>{html.escape(str(model.get('model_name') or model_id))}</th><td>{cap // 1024}K</td>"
            f"<td>{actual}</td><td>{result.get('hits', 0)}/{result.get('cases', 0)}</td>"
            f"<td>{html.escape(state)}</td><td>{_fmt(peak.get('max'), 0)} MiB</td>"
            f"<td>{html.escape(reasons)}</td></tr>"
        )
    highest_text = " / ".join(
        f"{source}: {cap // 1024}K" for source, cap in sorted(highest.items())
    ) or "本次没有已验证可用的档位"
    return (
        "<section class='panel capacity-panel'><h2>上下文容量</h2>"
        f"<p>最高已验证档：{html.escape(highest_text)}。仅代表已选档位在本次召回任务中的结果。</p>"
        "<div class='table-wrap'><table><thead><tr><th>模型 / 配置</th><th>上限</th><th>真实输入 token</th>"
        "<th>命中</th><th>状态</th><th>VRAM 峰值</th><th>原因</th></tr></thead><tbody>"
        + "".join(rows) + "</tbody></table></div></section>"
    )


def _md_cell(value: Any) -> str:
    return str(value if value is not None else "—").replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def _md_snapshot_settings(run_dir: Path, model_id: str, phase: str = "solo", uniform: bool = False) -> str | None:
    suffix = "" if phase == "solo" else f"-{phase}"
    config = read_json(run_dir / "configs" / f"{model_id}-round-1{suffix}.json", {}) or {}
    if not isinstance(config, dict):
        return None
    args = [str(item) for item in config.get("args") or []]
    safe_flags = {"--max-context", "--kv", "--kv-resident", "--vram-reserve-mib", "--prefill",
                  "--mtp", "--spec", "--expert-vram", "--batch", "--rope-scaling", "--rope-scale",
                  "--yarn-orig-ctx", "--vision"}
    if uniform:
        safe_flags.update({"--spec-min-p", "--pcie-frac", "--pool-workers", "--resident-budget-gib",
                           "--adapt-every", "--adapt-swaps", "--adapt-decay", "--prompt-cache"})
    shown = []
    for index, item in enumerate(args):
        if item not in safe_flags:
            continue
        value = args[index + 1] if index + 1 < len(args) and not args[index + 1].startswith("--") else None
        if value and ("/" in value or "\\" in value or value.lower().endswith((".gguf", ".bin"))):
            value = "<文件>"
        shown.append(item if value is None else f"{item} {value}")
    for key in ("arch", "backend", "parallel", "gpu"):
        if config.get(key) is not None:
            shown.append(f"{key}={config[key]}")
    if uniform and (config.get("env") or {}).get("STRATA_ROUTE_TAIL_SKIP") is not None:
        shown.append(f"STRATA_ROUTE_TAIL_SKIP={config['env']['STRATA_ROUTE_TAIL_SKIP']}")
    sampling = config.get("sampling") or {}
    if isinstance(sampling, dict):
        for key in ("temperature", "top_p", "top_k", "min_p"):
            if sampling.get(key) is not None:
                shown.append(f"{key}={sampling[key]}")
    return "; ".join(shown) or "快照未记录可展示的设置"


def _share_sentence(summary: dict[str, Any], ordered: list[tuple[str, dict[str, Any], dict[str, Any]]],
                    stages: set[str]) -> str:
    hardware = summary.get("hardware") or {}
    gpu_names = [str(gpu.get("name") or "") for gpu in hardware.get("gpus") or [] if gpu.get("name")]
    gpu_label = gpu_names[0].replace("NVIDIA GeForce ", "").replace("AMD Radeon ", "") if gpu_names else "本机"
    scope = f"Strata Benchmark｜{gpu_label}，"
    partial = _effective_run_state(summary) != "completed"
    suffix = "；本次测试部分完成。" if partial else "。"

    def short_name(model_id: str, spec: dict[str, Any], model: dict[str, Any]) -> str:
        source = str(spec.get("source_model_id") or model.get("source_model_id") or model_id)
        name = source.removeprefix("strata-")
        tier = model.get("context_tier") or spec.get("context_tier")
        if isinstance(tier, int) and tier > 0:
            name += f"@{tier // 1024}K"
        return name

    if "performance" in stages and ordered:
        common = set.intersection(*(set(model.get("performance") or {}) for _, _, model in ordered))
        choices = [str(item[0]) for item in ((summary.get("manifest") or {}).get("request") or {}).get("performance_cases") or []
                   if isinstance(item, (list, tuple)) and item]
        case_ids = [f"performance-{name}" for name in choices] + sorted(common)
        for case_id in dict.fromkeys(case_ids):
            if case_id not in common:
                continue
            parts = []
            for model_id, spec, model in ordered:
                result = (model.get("performance") or {}).get(case_id) or {}
                speed = (result.get("decode_tps") or {}).get("median")
                count = (result.get("decode_tps") or result.get("prompt_tps") or {}).get("n")
                if not isinstance(speed, (int, float)) or not math.isfinite(speed) or not isinstance(count, int) or count < 1:
                    break
                parts.append(f"{short_name(model_id, spec, model)} {speed:.2f} tok/s（n={count}）")
            if len(parts) == len(ordered):
                label = case_id.removeprefix("performance-").upper()
                sentence = scope + f"{label} 输入 Decode 中位数：" + "、".join(parts) + suffix
                if len(sentence) <= 180:
                    return sentence
                return scope + f"{len(parts)} 款模型的 {label} 输入 Decode 中位数已完成对照，详见下表" + suffix
    if "load" in stages and ordered:
        candidates = []
        for model_id, spec, model in ordered:
            rows = [row for row in model.get("load") or [] if row.get("clients") == 2
                    and isinstance(row.get("total_tps"), (int, float)) and not row.get("errors")]
            if not rows:
                break
            candidates.append(f"{short_name(model_id, spec, model)} {rows[0]['total_tps']:.2f} tok/s")
        if len(candidates) == len(ordered):
            sentence = scope + "2 客户端总吞吐：" + "、".join(candidates) + suffix
            if len(sentence) <= 180:
                return sentence
    if "capacity" in stages and ordered:
        parts = []
        for model_id, spec, model in ordered:
            capacity = model.get("capacity") or {}
            if not capacity.get("cases"):
                break
            status = {"verified": "通过", "failed": "未通过", "insufficient": "证据不足"}.get(capacity.get("status"), "未判定")
            parts.append(f"{short_name(model_id, spec, model)} {status}（{capacity.get('hits', 0)}/{capacity['cases']}）")
        if len(parts) == len(ordered):
            sentence = scope + "容量召回：" + "、".join(parts) + suffix
            if len(sentence) <= 180:
                return sentence
    if "agent" in stages and ordered:
        parts = []
        for model_id, spec, model in ordered:
            agent = model.get("agent") or {}
            if not agent.get("cases"):
                break
            parts.append(f"{short_name(model_id, spec, model)} {agent.get('passed', 0)}/{agent['cases']}")
        if len(parts) == len(ordered):
            sentence = scope + "内置 Agent 题集断言通过：" + "、".join(parts) + suffix
            if len(sentence) <= 180:
                return sentence
    if "needle" in stages and ordered:
        parts = []
        for model_id, spec, model in ordered:
            needle = model.get("needle") or {}
            if not needle.get("cases"):
                break
            parts.append(f"{short_name(model_id, spec, model)} {needle.get('found', 0)}/{needle['cases']}")
        if len(parts) == len(ordered):
            sentence = scope + "长上下文召回命中：" + "、".join(parts) + suffix
            if len(sentence) <= 180:
                return sentence
    return scope + "本次无可比较的有效结果，请查看正文的执行状态。"


def _md_report(summary: dict[str, Any], records: list[dict[str, Any]] | None = None,
               run_dir: Path | None = None) -> str:
    request = ((summary.get("manifest") or {}).get("request") or {})
    models = summary.get("models") or {}
    specs = {str(spec.get("model_id")): spec for spec in request.get("models") or []
             if isinstance(spec, dict) and spec.get("model_id")}
    ordered = [(model_id, specs.get(model_id, {}), models.get(model_id, {}))
               for model_id in dict.fromkeys([*specs, *models])]
    selected_stages = request.get("stages")
    if selected_stages is None:
        selected_stages = [stage for stage in ("performance", "cache", "agent", "needle", "capacity", "load", "stability")
                           if any(model.get(stage) for model in models.values())]
    stages = set(selected_stages)
    state = _effective_run_state(summary)
    stage_names = {"performance": "基础性能", "cache": "对话缓存", "agent": "Agent 内置题集",
                   "needle": "长上下文召回", "capacity": "上下文容量", "load": "并发性能",
                   "stability": "短时稳定性"}
    hardware = summary.get("hardware") or {}
    lines = ["# Strata Benchmark 对照摘要", "", "## 一句话分享", "",
             _share_sentence(summary, ordered, stages), "", "## 测试条件", "",
             f"- 状态：{STAGE_STATUS_LABELS.get(state, state)}；预设：{_md_cell(request.get('preset_label') or request.get('preset'))}；重复轮数：{_md_cell(request.get('rounds'))}；模型数：{len(ordered)}。",
             "- 选中项目：" + ("、".join(stage_names.get(stage, stage) for stage in selected_stages) or "未记录") + "。"]
    gpus = hardware.get("gpus") or []
    if gpus:
        lines.append("- GPU：" + " / ".join(_md_cell(gpu.get("name")) for gpu in gpus) + "。")
    if hardware.get("installed_ram_bytes"):
        lines.append(f"- 内存：{_fmt(hardware['installed_ram_bytes'] / 1024**3)} GiB。")
    if hardware.get("strata_engine_version"):
        lines.append(f"- Strata 版本：{_md_cell(hardware['strata_engine_version'])}。")
    if hardware.get("strata_git_revision"):
        lines.append(f"- Strata commit：{_md_cell(hardware['strata_git_revision'])}。")
    if hardware.get("gpu_power_limits"):
        watts = [f"{_fmt(item.get('watts'), 0)} W" for item in hardware["gpu_power_limits"] if item.get("watts") is not None]
        if watts:
            lines.append("- GPU 功率上限：" + " / ".join(watts) + "。")
    if request.get("uniform_config"):
        lines.append("- 对照条件：使用本次报告的模型配置副本，统一测试相关变量；各模型原有调优保留，日常配置未改动。")
    if "performance" in stages:
        lines.append("- 基础性能请求：temperature=0、seed=1、关闭 prompt cache；输入 token 数以实测为准。")

    records = records or []
    if "performance" in stages:
        lines += ["", "## 基础性能", "", "| 模型 | 配置上限 | 输入档 | 实测输入 token | 样本 n | Prompt 中位数 tok/s | Decode 中位数 tok/s | 引擎预填充中位数 秒 | VRAM 峰值 MiB | 整机 RAM 峰值 GiB | RAM 占比峰值 | Strata RSS 峰值 GiB |",
                  "| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
        row_count = 0
        for model_id, spec, model in ordered:
            tier = model.get("context_tier") or spec.get("context_tier")
            for case_id, result in (model.get("performance") or {}).items():
                if not (result.get("prompt_tps") or {}).get("n"):
                    continue
                tokens = [row["prompt_tokens"] for row in records if row.get("model_id") == model_id
                          and row.get("stage") == "performance" and row.get("case_id") == case_id
                          and row.get("status") == "success" and isinstance(row.get("prompt_tokens"), int)]
                actual = f"{min(tokens):,}" if tokens and min(tokens) == max(tokens) else (
                    f"{min(tokens):,}–{max(tokens):,}" if tokens else "—")
                metric = lambda name, key="median": (result.get(name) or {}).get(key)
                lines.append("| " + " | ".join(_md_cell(value) for value in (
                    model.get("model_name") or spec.get("model_name") or model_id,
                    f"{tier // 1024}K" if isinstance(tier, int) else "—",
                    case_id.removeprefix("performance-").upper(), actual,
                    (result.get("prompt_tps") or {}).get("n", "—"), _fmt(metric("prompt_tps")),
                    _fmt(metric("decode_tps")), _fmt(metric("prefill_seconds")),
                    _fmt(metric("vram_peak_mib", "max"), 0), _fmt(metric("system_ram_peak_gib", "max")),
                    _fmt_percent(metric("system_ram_peak_percent", "max")), _fmt(metric("rss_peak_gib", "max")),
                )) + " |")
                row_count += 1
        if not row_count:
            lines.append("| 暂无有效性能结果 | — | — | — | — | — | — | — | — | — | — | — |")
        lines += ["", "注：配置上限不是本次输入长度；引擎预填充来自 `prompt_ms`，不等于客户端 TTFT。内存峰值来自约 1 秒间隔采样。"]

    if "load" in stages:
        lines += ["", "## 并发性能", "", "| 模型 | 输入档 | 实测输入 token | 客户端 | 引擎槽数 | 总 tok/s | 单请求 tok/s | TTFT P50 秒 | 输出重叠 秒 | 缓存复用上限 | 错误 |",
                  "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
        count = 0
        for model_id, spec, model in ordered:
            for row in model.get("load") or []:
                low, high = row.get("prompt_tokens_min"), row.get("prompt_tokens_max")
                actual = f"{low:,}–{high:,}" if isinstance(low, int) and isinstance(high, int) else "—"
                lines.append("| " + " | ".join(_md_cell(value) for value in (
                    model.get("model_name") or spec.get("model_name") or model_id,
                    row.get("input_length") or "短输入", actual, row.get("clients"), row.get("serving_slots"),
                    _fmt(row.get("total_tps")), _fmt(row.get("per_req_tps")), _fmt(row.get("first_p50")),
                    _fmt(row.get("output_overlap_seconds")), _fmt(row.get("cached_tokens_max"), 0), row.get("errors"),
                )) + " |")
                count += 1
        if not count:
            lines.append("| 暂无有效并发结果 | — | — | — | — | — | — | — | — | — | — |")

    compact = (("cache", "对话缓存", "Cache 预填充中位数 秒 | 复用 token 中位数"),
               ("agent", "Agent 内置题集", "断言通过 | API 成功 / 预期"),
               ("needle", "长上下文召回", "命中 / 题数"),
               ("stability", "短时稳定性", "成功 / 请求 | Decode 中位数 tok/s"))
    for stage, title, header in compact:
        if stage not in stages:
            continue
        lines += ["", f"## {title}", "", f"| 模型 | {header} |",
                  "| --- |" + " --- |" * (header.count("|") + 1)]
        for model_id, spec, model in ordered:
            name = model.get("model_name") or spec.get("model_name") or model_id
            coverage = (model.get("stage_coverage") or {}).get(stage)
            value = "未执行"
            if stage == "cache" and model.get("cache") and (coverage or {}).get("state") != "not_run":
                cache = model["cache"]
                value = f"{_fmt((cache.get('prefill_seconds') or {}).get('median'))} | {_fmt((cache.get('reused_tokens') or {}).get('median'), 0)}"
            elif stage == "agent" and model.get("agent") and (coverage or {}).get("state") != "not_run":
                agent = model["agent"]
                value = f"{_reported_stage_metric(model, stage, agent.get('passed', 0), agent.get('cases', 0))} | {_stage_result_text(coverage)}"
            elif stage == "needle" and model.get("needle") and (coverage or {}).get("state") != "not_run":
                needle = model["needle"]
                value = _reported_stage_metric(model, stage, needle.get("found", 0), needle.get("cases", 0))
            elif stage == "stability" and model.get("stability") and (coverage or {}).get("state") != "not_run":
                stability = model["stability"]
                value = f"{stability.get('successes', 0)}/{stability.get('requests', 0)} | {_fmt((stability.get('decode_tps') or {}).get('median'))}"
            if " | " not in value and stage in {"cache", "agent", "stability"}:
                value += " | —"
            lines.append(f"| {_md_cell(name)} | {value} |")
        if stage == "agent":
            lines += ["", "注：通过数仅表示内置题集断言通过率，不代表总体智力或连续 Agent 能力。"]
        elif stage == "cache":
            lines += ["", "注：新版 Benchmark 的首轮约 32K 实测输入需在目标 ±5% 内，两次追问各需复用至少目标 40% 的 token；历史运行以原始记录为准。"]
        elif stage == "needle":
            lines += ["", "注：新版 Benchmark 按服务端 tokenizer 校准并核验输入 ±5%；命中率分母包含请求失败和缺失的应测题。历史运行以原始记录为准。"]
        elif stage == "stability":
            lines += ["", "注：新版 Benchmark 只有在请求返回有效内容和正数输出 token 时才计为成功；历史运行以原始记录为准。"]

    if "capacity" in stages:
        lines += ["", "## 上下文容量", "", "| 模型 | 配置上限 | 实测输入 token | 命中 / 题数 | 判定 |",
                  "| --- | ---: | ---: | ---: | --- |"]
        for model_id, spec, model in ordered:
            cap = model.get("context_tier") or spec.get("context_tier")
            result = model.get("capacity") or {}
            low, high = result.get("actual_prompt_tokens_min"), result.get("actual_prompt_tokens_max")
            actual = f"{low:,}–{high:,}" if isinstance(low, int) and isinstance(high, int) else "—"
            status = {"verified": "已验证", "failed": "召回未通过", "insufficient": "证据不足"}.get(result.get("status"), "未执行")
            tier_text = f"{cap // 1024}K" if isinstance(cap, int) else "—"
            lines.append(f"| {_md_cell(model.get('model_name') or spec.get('model_name') or model_id)} | "
                         f"{tier_text} | {actual} | "
                         f"{result.get('hits', 0)}/{result.get('cases', 0)} | {status} |")

    problems = []
    for model_id, spec, model in ordered:
        name = model.get("model_name") or spec.get("model_name") or model_id
        for stage, coverage in (model.get("stage_coverage") or {}).items():
            if stage in stages or stage in {"startup", "warmup"}:
                if coverage.get("state") != "completed" or coverage.get("failures"):
                    problems.append(f"{name} / {stage}：{_stage_result_text(coverage)}，失败 {coverage.get('failures', 0)}。")
    if summary.get("record_parse_errors"):
        problems.append(f"原始记录解析错误 {len(summary['record_parse_errors'])} 条。")
    if problems or state != "completed":
        lines += ["", "## 执行异常", ""] + ([f"- {_md_cell(item)}" for item in problems] or ["- 测试未完整完成，详见完整报告。"])
    lines += ["", "## 详细数据", "", "- [完整网页报告](report.html) · [机器可读汇总](summary.json) · [逐请求原始记录](raw-results.jsonl)", ""]
    return "\n".join(lines)


def _html_report(summary: dict[str, Any], records: list[dict[str, Any]] | None = None,
                 run_dir: Path | None = None) -> str:
    records = records or []
    uniform_mode = bool(((summary.get("manifest") or {}).get("request") or {}).get("uniform_config"))
    rows = []
    performance_charts = []
    for model_id, model in summary.get("models", {}).items():
        for case_id, result in model.get("performance", {}).items():
            rows.append(
                "<tr>"
                f"<td>{html.escape(str(model.get('model_name', model_id)))}</td>"
                f"<td>{html.escape(case_id)}</td>"
                f"<td>{result['prompt_tps']['n']}</td>"
                f"<td>{_fmt(result['prompt_tps']['median'])}</td>"
                f"<td>{_fmt(result['decode_tps']['median'])}</td>"
                f"<td>{_fmt((result.get('prefill_seconds') or result.get('ttft_seconds') or {}).get('median'))}</td>"
                f"<td>{_fmt(result['vram_peak_mib']['max'], 0)}</td>"
                f"<td>{_fmt(result['system_ram_peak_gib']['max'])}</td>"
                f"<td>{_fmt_percent(result['system_ram_peak_percent']['max'])}</td>"
                f"<td>{_fmt(result['rss_peak_gib']['max'])}</td>"
                "</tr>"
            )
    for metric_key, label, unit in (
        ("prompt_tps", "Prompt 处理速度", "tok/s"),
        ("decode_tps", "Decode 生成速度", "tok/s"),
    ):
        chart_rows = []
        values = [
            case[metric_key]["median"]
            for model in summary.get("models", {}).values()
            for case in model.get("performance", {}).values()
            if isinstance(case.get(metric_key), dict)
            and isinstance(case[metric_key].get("median"), (int, float))
        ]
        top = max(values, default=0) or 1
        for model_id, model in summary.get("models", {}).items():
            for case_id, case in model.get("performance", {}).items():
                stats = case.get(metric_key) or {}
                value = stats.get("median")
                if not isinstance(value, (int, float)):
                    continue
                width = max(0.0, min(100.0, float(value) / top * 100))
                chart_rows.append(
                    "<div class='bar-row'>"
                    f"<span class='bar-label'>{html.escape(str(model.get('model_name', model_id)))} · {html.escape(str(case_id))}</span>"
                    f"<span class='bar-track'><span class='bar-fill' style='width:{width:.2f}%'></span></span>"
                    f"<span class='bar-value'>{_fmt(value)} {unit} <small>(范围 {_fmt(stats.get('min'))}–{_fmt(stats.get('max'))})</small></span>"
                    "</div>"
                )
        performance_charts.append(
            f"<section class='chart card'><h3>{label}</h3>{''.join(chart_rows) or '<p class=\"muted\">暂无有效数据</p>'}</section>"
        )
    cards = []
    capability_rows=[]
    load_rows=[]
    load_charts = []
    load_values = [
        row.get("total_tps")
        for model in summary.get("models", {}).values()
        for row in model.get("load", [])
        if isinstance(row.get("total_tps"), (int, float))
    ]
    load_top = max(load_values, default=0) or 1
    for model_id, model in summary.get("models", {}).items():
        agent, needle = model.get("agent", {}), model.get("needle", {})
        startup=model.get("startup_seconds",{});cache=model.get("cache",{});stability=model.get("stability",{})
        cards.append(
            f"<section class='card'><h2>{html.escape(str(model.get('model_name', model_id)))}</h2>"
            f"<p>Agent：<b>{html.escape(_reported_stage_metric(model, 'agent', agent.get('passed', 0), agent.get('cases', 0)))}</b>　"
            f"Needle：<b>{html.escape(_reported_stage_metric(model, 'needle', needle.get('found', 0), needle.get('cases', 0)))}</b></p>"
            f"<p>成功 {model.get('successes', 0)}　失败 {model.get('failures', 0)}　跳过 {model.get('skipped', 0)}</p></section>"
        )
        capability_rows.append("<tr>"+f"<td>{html.escape(str(model.get('model_name',model_id)))}</td><td>{_fmt(startup.get('median'))}</td><td>{_fmt((cache.get('prefill_seconds') or cache.get('ttft_seconds') or {}).get('median'))}</td><td>{_fmt((cache.get('reused_tokens') or {}).get('median'),0)}</td><td>{html.escape(_reported_stage_metric(model, 'agent', agent.get('passed',0), agent.get('cases',0)))}</td><td>{html.escape(_reported_stage_metric(model, 'needle', needle.get('found',0), needle.get('cases',0)))}</td><td>{html.escape(_stage_result_text(model.get('stage_coverage', {}).get('stability')))}</td></tr>")
        for load in model.get("load",[]):
            slot_cell = f"<td>{load.get('serving_slots', '—')}</td>" if uniform_mode else ""
            measured = f"{load['prompt_tokens_min']:,}–{load['prompt_tokens_max']:,}" if isinstance(load.get('prompt_tokens_min'), int) and isinstance(load.get('prompt_tokens_max'), int) else "未记录"
            load_rows.append("<tr>"+f"<td>{html.escape(str(model.get('model_name',model_id)))}</td><td>{html.escape(str(load.get('input_length') or '短输入'))}</td><td>{measured}</td><td>{load.get('clients','—')}</td>{slot_cell}<td>{_fmt(load.get('cached_tokens_max'), 0)}</td><td>{_fmt(load.get('output_overlap_seconds'))}</td><td>{_fmt(load.get('total_tps'))}</td><td>{_fmt(load.get('per_req_tps'))}</td><td>{_fmt(load.get('first_p50'))}/{_fmt(load.get('first_p95'))}</td><td>{_fmt(load.get('lat_p50'))}/{_fmt(load.get('lat_p95'))}</td><td>{load.get('errors','—')}</td></tr>")
            value = load.get("total_tps")
            if isinstance(value, (int, float)):
                width = max(0.0, min(100.0, float(value) / load_top * 100))
                load_charts.append(
                    "<div class='bar-row'>"
                    f"<span class='bar-label'>{html.escape(str(model.get('model_name', model_id)))} · {html.escape(str(load.get('input_length') or '短输入'))} · {load.get('clients', '—')} 客户端</span>"
                    f"<span class='bar-track'><span class='bar-fill load-fill' style='width:{width:.2f}%'></span></span>"
                    f"<span class='bar-value'>{_fmt(value)} tok/s <small>单请求 {_fmt(load.get('per_req_tps'))} tok/s</small></span>"
                    "</div>"
                )
    memory_rows = []
    for model_id, model in summary.get("models", {}).items():
        for stage in model.get("memory_by_stage", {}).values():
            memory_rows.append(
                "<tr>"
                f"<td>{html.escape(str(model.get('model_name', model_id)))}</td>"
                f"<td>{html.escape(str(stage['label']))}</td>"
                f"<td>{_fmt(stage['system_ram_peak_gib']['max'])}</td>"
                f"<td>{_fmt_percent(stage['system_ram_peak_percent']['max'])}</td>"
                f"<td>{_fmt(stage['rss_peak_gib']['max'])}</td>"
                f"<td>{_fmt(stage['vram_peak_mib']['max'], 0)}</td></tr>"
            )
    coverage_rows = []
    for model_id, model in summary.get("models", {}).items():
        for stage, coverage in model.get("stage_coverage", {}).items():
            expected = coverage.get("expected")
            coverage_rows.append(
                "<tr>"
                f"<td>{html.escape(str(model.get('model_name', model_id)))}</td>"
                f"<td>{html.escape(stage)}</td>"
                f"<td>{STAGE_STATUS_LABELS.get(coverage.get('state'), coverage.get('state'))}</td>"
                f"<td>{coverage.get('successes', 0)} / {html.escape(str(expected if expected is not None else '—'))}</td>"
                f"<td>{coverage.get('failures', 0)}</td><td>{coverage.get('skipped', 0)}</td></tr>"
            )
    raw_state = _effective_run_state(summary)
    state = html.escape(STAGE_STATUS_LABELS.get(raw_state, raw_state))
    manifest = summary.get("manifest") or {}
    request = manifest.get("request") or {}
    parameter_rows = []
    model_parameter_rows = []
    for key, value in request.items():
        if key == "models":
            for model in value if isinstance(value, list) else []:
                if not isinstance(model, dict):
                    continue
                model_parameter_rows.append(
                    "<tr>"
                    f"<td>{html.escape(str(model.get('model_name') or model.get('model_id') or '模型'))}</td>"
                    f"<td>{html.escape(str(model.get('config_path') or '—'))}</td>"
                    f"<td><code>{html.escape(str(model.get('config_hash') or '—'))}</code></td>"
                    f"<td>{html.escape(str(model.get('port') or '—'))}</td></tr>"
                )
            continue
        shown = json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list)) else str(value)
        parameter_rows.append(
            f"<tr><th>{html.escape(str(key))}</th><td>{html.escape(shown)}</td></tr>"
        )
    stage_options = sorted({str(record.get("stage") or "unknown") for record in records})
    model_options = sorted({str(record.get("model_id") or "unknown") for record in records})
    status_options = sorted({str(record.get("status") or "unknown") for record in records})
    detail_rows = []
    for record in records:
        model_id = str(record.get("model_id") or "unknown")
        stage = str(record.get("stage") or "unknown")
        status = str(record.get("status") or "unknown")
        model_name = str(record.get("model_name") or model_id)
        case_id = str(record.get("case_id") or "—")
        summary_fields = []
        for key in ("prompt_tokens_per_second", "decode_tokens_per_second", "prefill_seconds", "ttft_seconds", "found", "length", "depth", "clients", "cached_tokens_max", "output_overlap_seconds", "total_tps", "errors", "error"):
            if key in record:
                value = record[key]
                if isinstance(value, (dict, list)):
                    value = json.dumps(value, ensure_ascii=False)
                summary_fields.append(f"<span><b>{html.escape(key)}</b>: {html.escape(str(value))}</span>")
        full_record = html.escape(json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True))
        detail_rows.append(
            f'<tr class="result-row" data-model="{html.escape(model_id, quote=True)}" data-stage="{html.escape(stage, quote=True)}" data-status="{html.escape(status, quote=True)}" data-search="{html.escape((model_name + " " + case_id).lower(), quote=True)}">'
            f"<td>{html.escape(model_name)}</td><td>{html.escape(stage)}</td><td>{html.escape(case_id)}</td>"
            f"<td>{html.escape(str(record.get('round') or '—'))}</td><td><span class='status status-{html.escape(status, quote=True)}'>{html.escape(status)}</span></td>"
            f"<td class='record-metrics'>{''.join(summary_fields) or '—'}</td>"
            f"<td><details><summary>查看完整字段（{len(record)}）</summary><pre>{full_record}</pre></details></td></tr>"
        )
    filters = (
        "<div class='filters'>"
        "<label>模型 <select id='filter-model'><option value=''>全部</option>"
        + "".join(f"<option value='{html.escape(x, quote=True)}'>{html.escape(x)}</option>" for x in model_options)
        + "</select></label><label>阶段 <select id='filter-stage'><option value=''>全部</option>"
        + "".join(f"<option value='{html.escape(x, quote=True)}'>{html.escape(x)}</option>" for x in stage_options)
        + "</select></label><label>状态 <select id='filter-status'><option value=''>全部</option>"
        + "".join(f"<option value='{html.escape(x, quote=True)}'>{html.escape(x)}</option>" for x in status_options)
        + "</select></label><label>搜索 <input id='filter-search' type='search' placeholder='模型 / 测试用例'></label>"
        "<button id='reset-filters' type='button'>清除筛选</button><span id='visible-count' aria-live='polite'></span></div>"
    )
    power_label = _power_limit_label(summary.get("hardware") or {})
    power_html = f"<p>测试开始时的 GPU 功率上限：{html.escape(power_label)}</p>" if power_label else ""
    request_stages = ((summary.get("manifest") or {}).get("request") or {}).get("stages") or []
    agent_case_count = request.get("agent_case_count")
    agent_scope = (f"本次内置 {agent_case_count} 道单次请求题" if isinstance(agent_case_count, int)
                   else "内置单次请求题")
    sampling_note = "配置快照中的采样值是服务默认值；基础性能正式请求覆盖 temperature=0、seed=1、reasoning_effort=none、cache_prompt=false，生成上限 256 tokens。" if "performance" in request_stages else ""
    uniform_html = f"<p>对照条件默认生效。普通、缓存和并发阶段分别使用临时配置副本；并发槽数从服务端核验。保留各模型原有调优，原模型配置未修改。{sampling_note}</p>" if uniform_mode else ""
    phase_settings_html = ""
    if uniform_mode and run_dir:
        phase_rows = []
        specs = ((summary.get("manifest") or {}).get("request") or {}).get("models") or []
        for spec in specs:
            if not isinstance(spec, dict) or not spec.get("model_id"):
                continue
            model_id = str(spec["model_id"])
            name = str(spec.get("model_name") or model_id)
            for phase, label in (("solo", "普通"), ("cache", "缓存"), ("load", "并发")):
                settings = _md_snapshot_settings(run_dir, model_id, phase, uniform=True)
                if settings:
                    phase_rows.append(f"<tr><td>{html.escape(name)} / {label}</td><td>{html.escape(settings)}</td></tr>")
        if phase_rows:
            phase_settings_html = ("\n<h3>实际阶段参数</h3><div class='table-wrap'><table><thead>"
                                   "<tr><th>模型 / 阶段</th><th>配置副本中的参数</th></tr></thead><tbody>"
                                   + "".join(phase_rows) + "</tbody></table></div>")
    slot_header = "<th>引擎实测槽数</th>" if uniform_mode else ""
    load_colspan = 12 if uniform_mode else 11
    empty_load_rows = f'<tr><td colspan="{load_colspan}" class="empty">暂无数据</td></tr>'
    capacity_html = _capacity_table_html(summary)
    return f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Strata Benchmark</title><style>
body{{font-family:Segoe UI,"Microsoft YaHei",sans-serif;margin:0;background:#f4f6f8;color:#20242a}}main{{max-width:1320px;margin:auto;padding:28px}}
.meta,.muted{{color:#5f6875}}.grid,.charts{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr));gap:14px;margin:20px 0}}
.card{{background:white;border:1px solid #dfe3e8;border-radius:10px;padding:16px;box-shadow:0 2px 8px #0000000a;min-width:0}}table{{width:100%;border-collapse:collapse;background:white}}
th,td{{padding:10px;border:1px solid #dfe3e8;text-align:right;vertical-align:top}}th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){{text-align:left}}th{{background:#eef2f6;position:sticky;top:0;z-index:1}}
code{{background:#eef2f6;padding:2px 5px;border-radius:4px}}.links a{{margin-right:16px}}.table-wrap{{overflow:auto;border:1px solid #dfe3e8;border-radius:8px;background:white}}
.bar-row{{display:grid;grid-template-columns:minmax(130px,1fr) minmax(100px,2fr) minmax(150px,1fr);gap:10px;align-items:center;margin:12px 0}}.bar-label{{overflow-wrap:anywhere}}.bar-track{{height:14px;border-radius:99px;background:#e8edf3;overflow:hidden}}.bar-fill{{display:block;height:100%;background:#2563eb;border-radius:99px}}.load-fill{{background:#0f766e}}.bar-value{{font-variant-numeric:tabular-nums}}small{{display:block;color:#667085;font-size:12px}}
.filters{{display:flex;flex-wrap:wrap;align-items:end;gap:12px;margin:14px 0;padding:14px;background:#fff;border:1px solid #dfe3e8;border-radius:8px}}label{{display:grid;gap:4px}}input,select,button{{font:inherit;padding:7px 9px;border:1px solid #b9c2cd;border-radius:6px;background:white;color:inherit}}button{{cursor:pointer}}.record-metrics{{text-align:left;min-width:180px}}.record-metrics span{{display:block;margin:2px 0;overflow-wrap:anywhere}}.status{{font-weight:600}}.status-failure{{color:#b42318}}.status-success{{color:#027a48}}.status-skipped{{color:#9a6700}}details summary{{cursor:pointer;color:#175cd3}}pre{{white-space:pre-wrap;overflow-wrap:anywhere;max-height:420px;overflow:auto;min-width:280px;margin:8px 0;padding:12px;background:#101828;color:#f2f4f7;border-radius:6px;text-align:left;font-size:12px}}.parameters{{max-width:100%;text-align:left}}.parameters th{{width:220px}}.empty{{text-align:center;color:#667085;padding:24px}}
@media(max-width:700px){{main{{padding:14px}}.bar-row{{grid-template-columns:1fr;gap:5px}}.bar-value{{font-size:14px}}th,td{{padding:8px}}}}
</style></head>
<body><main><h1>Strata 批量 Benchmark</h1><p class="meta">状态：<code>{state}</code>　生成：{html.escape(str(summary.get('generated_at')))}　原始记录：{summary.get('record_count', 0)}</p><p class="links"><a href="report-preview.html">打开截图概览 / 导出分享 PNG</a></p>
<div class="grid">{''.join(cards)}</div>
<h2>性能速度对比</h2><p class="muted">条形长度按本报告内该指标最大中位数归一化；同时列出中位数和实测范围。</p><div class="charts">{''.join(performance_charts)}</div>
<h2>性能汇总</h2><p class="muted">同一份本地语料按各模型 tokenizer 校准；不同 tokenizer 的截断位置可能略有差异。新版 Benchmark 仅将真实输入、冷缓存、有效输出和速度指标均通过核验的请求计为有效样本；历史运行以原始记录为准。引擎预填充来自 prompt_ms，不是客户端 TTFT。</p><div class="table-wrap"><table><thead><tr><th>模型</th><th>测试</th><th>样本</th><th>Prompt tok/s</th><th>Decode tok/s</th><th>引擎预填充秒</th><th>VRAM 峰值 MiB</th><th>整机 RAM 峰值 GiB</th><th>RAM 占比峰值</th><th>Strata RSS 峰值 GiB</th></tr></thead><tbody>{''.join(rows) or '<tr><td colspan="10" class="empty">暂无数据</td></tr>'}</tbody></table></div>
<h2>关键阶段内存峰值</h2><p class="muted">仅列实际取得采样的关键阶段；并发内存反映整个并发阶段，不拆分到单一客户端档。</p><div class="table-wrap"><table><thead><tr><th>模型</th><th>阶段</th><th>整机 RAM 峰值 GiB</th><th>RAM 占比峰值</th><th>Strata RSS 峰值 GiB</th><th>VRAM 峰值 MiB</th></tr></thead><tbody>{''.join(memory_rows) or '<tr><td colspan="6" class="empty">暂无内存采样数据</td></tr>'}</tbody></table></div>
<h2>能力、缓存与稳定性</h2><p class="muted">Agent 数字是{html.escape(agent_scope)}的断言通过数，仅代表本题集；工具与历史消息由题面提供，未实际执行连续 Agent 流程。缓存首轮输入和追问复用、Needle 实际输入、稳定性有效输出均按逐项记录核验；历史运行以其原始记录为准。预填充耗时来自引擎 prompt_ms，不是客户端 TTFT。</p><div class="table-wrap"><table><thead><tr><th>模型</th><th>启动 秒</th><th>Cache 预填充秒</th><th>复用 token</th><th>内置 Agent 题集通过</th><th>Needle</th><th>稳定性</th></tr></thead><tbody>{''.join(capability_rows) or '<tr><td colspan="7" class="empty">暂无数据</td></tr>'}</tbody></table></div>
{capacity_html}
<h2>阶段执行完整性</h2><p class="muted">“未选择”表示本次没有要求该阶段；“未执行”表示已要求但没有产生记录；有失败、跳过或样本不足时不会显示为完整。</p><div class="table-wrap"><table><thead><tr><th>模型</th><th>阶段</th><th>状态</th><th>成功 / 预期</th><th>失败</th><th>跳过</th></tr></thead><tbody>{''.join(coverage_rows) or '<tr><td colspan="6" class="empty">清单没有要求的测试阶段</td></tr>'}</tbody></table></div>
<h2>并发吞吐对比</h2><section class="card chart">{''.join(load_charts) or '<p class="muted">暂无并发数据</p>'}</section><div class="table-wrap"><table><thead><tr><th>模型</th><th>输入档</th><th>实测输入 tokens</th><th>客户端</th>{slot_header}<th>缓存复用上限</th><th>输出重叠秒</th><th>总 tok/s</th><th>单请求 tok/s</th><th>TTFT P50/P95</th><th>延迟 P50/P95</th><th>错误</th></tr></thead><tbody>{''.join(load_rows) or empty_load_rows}</tbody></table></div>
<h2 id="run-parameters">本次测试参数</h2>{uniform_html}<div class="table-wrap"><table class="parameters"><tbody>{''.join(parameter_rows) or '<tr><td class="empty">清单未记录测试参数</td></tr>'}</tbody></table></div>
<h3>模型配置快照</h3><div class="table-wrap"><table><thead><tr><th>模型</th><th>配置路径</th><th>配置 SHA-256</th><th>服务端口</th></tr></thead><tbody>{''.join(model_parameter_rows) or '<tr><td colspan="4" class="empty">清单未记录模型快照</td></tr>'}</tbody></table></div>{phase_settings_html}
<h2>环境与口径</h2><p>系统：{html.escape(str((summary.get('hardware') or {}).get('platform') or '未获取'))}<br>CPU：{html.escape(str((summary.get('hardware') or {}).get('cpu') or '未获取'))}<br>RAM 总量：{_fmt((summary.get('hardware') or {}).get('installed_ram_bytes', 0) / (1024**3))} GiB<br>Strata 版本：<code>{html.escape(str((summary.get('hardware') or {}).get('strata_engine_version') or '未记录'))}</code><br>Strata commit：<code>{html.escape(str((summary.get('hardware') or {}).get('strata_git_revision') or '未获取'))}</code></p>{power_html}<p>RAM、Strata RSS 与 VRAM 峰值来自约 1 秒间隔采样；短于采样间隔的瞬时峰值可能未被捕获。性能阶段按设置轮数重复；Needle、并发和稳定性按清单所选档位执行。容量探测仅在选中时执行。实际 token 数和失败详情以逐项记录为准。</p>
<h2 id="all-results">全部逐项结果（{len(records)} 条）</h2>{filters}<div class="table-wrap"><table id="results-table"><thead><tr><th>模型</th><th>阶段</th><th>用例</th><th>轮次</th><th>状态</th><th>常用指标</th><th>完整原始字段</th></tr></thead><tbody>{''.join(detail_rows) or '<tr><td colspan="7" class="empty">暂无原始记录</td></tr>'}</tbody></table></div>
<p class="links"><a href="report.md">Markdown</a><a href="summary.json">Summary JSON</a><a href="raw-results.jsonl">Raw JSONL</a></p></main>
<script>
(()=>{{const model=document.getElementById('filter-model'),stage=document.getElementById('filter-stage'),status=document.getElementById('filter-status'),search=document.getElementById('filter-search'),rows=[...document.querySelectorAll('.result-row')],count=document.getElementById('visible-count');
function apply(){{let shown=0;for(const row of rows){{const visible=(!model.value||row.dataset.model===model.value)&&(!stage.value||row.dataset.stage===stage.value)&&(!status.value||row.dataset.status===status.value)&&(!search.value||row.dataset.search.includes(search.value.toLowerCase()));row.hidden=!visible;if(visible)shown++;}}count.textContent=`显示 ${{shown}} / ${{rows.length}} 条`;}}
for(const control of [model,stage,status,search])control.addEventListener('input',apply);document.getElementById('reset-filters').addEventListener('click',()=>{{for(const control of [model,stage,status,search])control.value='';apply();}});apply();}})();
</script></body></html>"""


def render_reports(run_dir: Path, summary: dict[str, Any] | None = None) -> dict[str, str]:
    summary = summary or build_summary(run_dir)
    records, _ = read_records(run_dir / "raw-results.jsonl")
    summary_path = run_dir / "summary.json"
    markdown_path = run_dir / "report.md"
    html_path = run_dir / "report.html"
    preview_path = run_dir / "report-preview.html"
    share_svg_path = run_dir / "share.svg"
    share_svg = render_share_svg(summary)
    atomic_json(summary_path, summary)
    markdown_path.write_text(_md_report(summary, records, run_dir), encoding="utf-8")
    html_path.write_text(_html_report(summary, records, run_dir), encoding="utf-8")
    preview_path.write_text(_html_overview_preview(summary, share_svg), encoding="utf-8")
    share_svg_path.write_text(share_svg, encoding="utf-8")
    return {
        "summary": str(summary_path),
        "markdown": str(markdown_path),
        "html": str(html_path),
        "preview": str(preview_path),
        "share_svg": str(share_svg_path),
    }


def _html_overview_preview(summary: dict[str, Any], share_svg: str | None = None) -> str:
    manifest = summary.get("manifest") or {}
    request = manifest.get("request") or {}
    hardware = summary.get("hardware") or {}
    models = summary.get("models") or {}
    completion = summary.get("completion") or {}
    run_state = _effective_run_state(summary)
    status_label = STAGE_STATUS_LABELS.get(run_state, run_state)
    state_class = "good" if run_state == "completed" else "warn"
    selected = _selected_stages(summary)

    raw_cases = request.get("performance_cases") or []
    case_labels = [str(case[0]) for case in raw_cases if isinstance(case, (list, tuple)) and case]
    if not case_labels:
        case_labels = sorted(
            {
                key.removeprefix("performance-")
                for model in models.values()
                for key in (model.get("performance") or {})
            },
            key=lambda label: int("".join(char for char in label if char.isdigit()) or 0),
        )
    maximum_decode = max(
        (
            (case.get("decode_tps") or {}).get("median") or 0
            for model in models.values()
            for case in (model.get("performance") or {}).values()
        ),
        default=0,
    ) or 1

    context_rows: list[str] = []
    for model_id, model in models.items():
        cells = []
        for label in case_labels:
            performance = model.get("performance") or {}
            case = performance.get(f"performance-{label}") or performance.get(label) or {}
            decode = case.get("decode_tps") or {}
            value = decode.get("median")
            width = max(0.0, min(100.0, float(value or 0) / maximum_decode * 100))
            spread = ""
            if decode.get("min") is not None and decode.get("max") is not None:
                spread = f" · 范围 {_fmt(decode.get('min'))}–{_fmt(decode.get('max'))}"
            cells.append(
                "<td><div class='metric-cell'>"
                f"<strong>{_fmt(value)} <small>tok/s</small></strong>"
                f"<span class='mini-track'><i style='width:{width:.1f}%'></i></span>"
                f"<small>Prompt {_fmt((case.get('prompt_tps') or {}).get('median'))} · "
                f"预填充 {_fmt((case.get('prefill_seconds') or case.get('ttft_seconds') or {}).get('median'))} 秒 · "
                f"n={decode.get('n', 0)}{html.escape(spread)}</small>"
                "</div></td>"
            )
        config_hash = str(model.get("config_hash") or "")[:8]
        context_rows.append(
            "<tr>"
            f"<th scope='row'>{html.escape(str(model.get('model_name') or model_id))}"
            f"<small>配置 {html.escape(config_hash or '未记录')}</small></th>"
            f"{''.join(cells)}</tr>"
        )

    load_rows: list[str] = []
    for model_id, model in models.items():
        for row in sorted(model.get("load") or [], key=lambda item: (str(item.get("input_length") or ""), item.get("clients") or 0)):
            measured = f"{row['prompt_tokens_min']:,}–{row['prompt_tokens_max']:,}" if isinstance(row.get('prompt_tokens_min'), int) and isinstance(row.get('prompt_tokens_max'), int) else "未记录"
            load_rows.append(
                "<tr>"
                f"<th scope='row'>{html.escape(str(model.get('model_name') or model_id))}</th>"
                f"<td>{html.escape(str(row.get('input_length') or '短输入'))}<small>实测 {measured} tokens · 缓存复用 {_fmt(row.get('cached_tokens_max'), 0)} · 输出重叠 {_fmt(row.get('output_overlap_seconds'))} 秒</small></td>"
                f"<td>{row.get('clients', '—')}</td>"
                f"<td>{html.escape(str(row.get('serving_slots') if row.get('serving_slots') is not None else '未记录'))}</td>"
                f"<td><b>{_fmt(row.get('per_req_tps'))}</b><small>tok/s · 单请求解码</small></td>"
                f"<td>{_fmt(row.get('total_tps'))}<small>tok/s · 总吞吐</small></td>"
                f"<td>{_fmt(row.get('first_p50'))} / {_fmt(row.get('first_p95'))}<small>秒 · TTFT P50/P95</small></td>"
                f"<td>{_fmt(row.get('lat_p50'))} / {_fmt(row.get('lat_p95'))}<small>秒 · 完成延迟 P50/P95</small></td>"
                f"<td>{row.get('errors', '—')}</td>"
                "</tr>"
            )

    model_rows: list[str] = []
    quick_columns = []
    if "load" in selected:
        quick_columns += ["整机 RAM 峰值", "Strata RSS 峰值", "VRAM 峰值"]
    if "cache" in selected:
        quick_columns += ["缓存预填充", "复用 token"]
    if "agent" in selected:
        quick_columns.append("内置 Agent 题集")
    if "needle" in selected:
        quick_columns.append("Needle 召回")
    if "stability" in selected:
        quick_columns.append("短时稳定性")
    for model_id, model in models.items():
        memory = model.get("memory_by_stage") or {}
        load_memory = memory.get("load") or {}
        agent = model.get("agent") or {}
        needle = model.get("needle") or {}
        cache = model.get("cache") or {}
        cells = []
        if "load" in selected:
            cells += [
                f"<td>{_fmt((load_memory.get('system_ram_peak_gib') or {}).get('max'))} GiB<small>并发阶段整机 RAM 峰值</small></td>",
                f"<td>{_fmt((load_memory.get('rss_peak_gib') or {}).get('max'))} GiB</td>",
                f"<td>{_fmt((load_memory.get('vram_peak_mib') or {}).get('max'), 0)} MiB</td>",
            ]
        if "cache" in selected:
            cells += [
                f"<td>{_fmt((cache.get('prefill_seconds') or {}).get('median'))} 秒</td>",
                f"<td>{_fmt((cache.get('reused_tokens') or {}).get('median'), 0)}</td>",
            ]
        if "agent" in selected:
            cells.append(f"<td>{html.escape(_reported_stage_metric(model, 'agent', agent.get('passed', 0), agent.get('cases', 0)))}</td>")
        if "needle" in selected:
            cells.append(f"<td>{html.escape(_reported_stage_metric(model, 'needle', needle.get('found', 0), needle.get('cases', 0)))}</td>")
        if "stability" in selected:
            cells.append(f"<td>{html.escape(_stage_result_text(model.get('stage_coverage', {}).get('stability')))}</td>")
        model_rows.append(
            "<tr>"
            f"<th scope='row'>{html.escape(str(model.get('model_name') or model_id))}</th>"
            f"{''.join(cells)}"
            "</tr>"
        )

    gpu_rows = hardware.get("gpus") or []
    gpu_label = " / ".join(
        f"{gpu.get('name', 'GPU')} · {_fmt((gpu.get('memory_total_mib') or 0) / 1024, 0)} GiB"
        for gpu in gpu_rows
    ) or "GPU 未获取"
    ram_gib = (hardware.get("installed_ram_bytes") or 0) / (1024**3)
    cpu = hardware.get("cpu_model") or hardware.get("cpu") or "CPU 未获取"
    if cpu.startswith("AMD64 Family "):
        cpu = "AMD64（具体型号未采集）"
    core_label = ""
    if hardware.get("physical_cpu_count") or hardware.get("logical_cpu_count"):
        core_label = f" · {hardware.get('physical_cpu_count', '—')}C/{hardware.get('logical_cpu_count', '—')}T"
    driver = ", ".join(str(gpu.get("driver_version")) for gpu in gpu_rows if gpu.get("driver_version"))
    contexts = " / ".join(case_labels) if case_labels else "未记录"
    load_contexts = " / ".join(str(label) for label in request.get("load_input_lengths") or []) or "未记录"
    clients = " / ".join(str(client) for client in request.get("load_clients") or []) or "未选择"
    requested_model_context = request.get("model_max_context")
    if isinstance(requested_model_context, int) or (isinstance(requested_model_context, str) and requested_model_context.isdigit()):
        model_context = f"{int(requested_model_context) // 1024}K"
    else:
        model_contexts = sorted({int(model["effective_max_context"]) for model in models.values() if model.get("effective_max_context")})
        model_context = " / ".join(f"{value // 1024}K" for value in model_contexts) or "未记录"
    load_rounds = request.get("load_rounds", 3)
    load_max_tokens = request.get("load_max_tokens", 256)
    stage_names = {"performance": "基础性能", "cache": "对话缓存", "agent": "Agent 内置题集",
                   "needle": "长上下文召回", "capacity": "上下文容量", "load": "并发性能",
                   "stability": "短时稳定性"}
    selected_labels = " / ".join(stage_names[stage] for stage in stage_names if stage in selected) or "未记录"
    meta_items = [f"<span><b>测试</b> {html.escape(str(request.get('preset_label') or request.get('preset') or '未记录'))}</span>",
                  f"<span><b>项目</b> {html.escape(selected_labels)}</span>",
                  f"<span><b>模型</b> {len(models)}</span>"]
    if "performance" in selected:
        meta_items += [f"<span><b>性能轮数</b> {html.escape(str(request.get('rounds', '—')))}</span>",
                       f"<span><b>性能输入</b> {html.escape(contexts)}</span>"]
    meta_items.append(f"<span><b>模型上下文</b> {html.escape(str(model_context))}</span>")
    if "load" in selected:
        meta_items += [f"<span><b>并发输入</b> {html.escape(load_contexts)}</span>",
                       f"<span><b>并发档位</b> {html.escape(clients)} 客户端</span>",
                       f"<span><b>并发负载</b> 每档 {html.escape(str(load_rounds))} 轮 · {html.escape(str(load_max_tokens))} tokens</span>"]
    engine_version = hardware.get("strata_engine_version")
    engine_version_label = f"v{engine_version}" if engine_version else "未记录"
    meta_items.append(f"<span><b>Strata</b> {html.escape(engine_version_label)}</span>")
    run_date = str(manifest.get("created_at") or summary.get("generated_at") or "未记录")
    run_date = run_date.replace("T", " ").replace("+00:00", " UTC")
    records = summary.get("record_count", 0)
    share_svg = share_svg or render_share_svg(summary)
    share_controls, share_script = export_controls_and_script(share_svg)
    power_label = _power_limit_label(hardware)
    power_html = f'<span><strong>功率上限</strong> {html.escape(power_label)}</span>' if power_label else ''
    capacity_html = _capacity_table_html(summary)
    performance_html = (f'<section class="panel"><div class="panel-title"><h2>输入上下文与生成速度</h2><p>Decode 中位数为主；显示 Prompt / 引擎预填充作补充</p></div><div class="table-wrap"><table class="context-table"><thead><tr><th>模型</th>{"".join(f"<th>{html.escape(label.upper())}</th>" for label in case_labels)}</tr></thead><tbody>{"".join(context_rows) or "<tr><td>暂无性能数据</td></tr>"}</tbody></table></div><p class="footnote">数字是各档位实测中位数，n 为有效样本数；范围显示重复测试的 min–max。配置上限与真实输入长度不同，跨模型比较时请核对输入档、配置和 Strata 版本。</p></section>'
                        if "performance" in selected else "")
    load_html = (f'<section class="panel"><div class="panel-title"><h2>并发时单独一条请求的速度</h2><p>主指标：单请求首 token 后解码 tok/s；总吞吐为辅助</p></div><p class="callout">单请求解码速度不含首 token 等待。总吞吐统计该档所有请求。TTFT 和完成延迟包含排队等待；缓存复用与输出重叠来自本次实测。</p><div class="table-wrap"><table class="load-table"><thead><tr><th>模型</th><th>输入档与实测 tokens</th><th>并发客户端</th><th>引擎槽数</th><th>单请求解码速度（主指标）</th><th>总吞吐（辅助）</th><th>TTFT P50 / P95</th><th>完成延迟 P50 / P95</th><th>错误</th></tr></thead><tbody>{"".join(load_rows) or "<tr><td colspan=\"9\">未执行并发测试</td></tr>"}</tbody></table></div></section>'
                 if "load" in selected else "")
    quick_note = "Agent 仅表示内置题集断言通过；Needle 表示本次召回命中。"
    if "load" in selected:
        quick_note += "内存为约 1 秒间隔采样的整个并发阶段峰值。"
    quick_html = (f'<section class="panel"><div class="panel-title"><h2>已选项目快速对比</h2><p>只展示本次所选项目的实测汇总</p></div><div class="table-wrap"><table class="score-table"><thead><tr><th>模型</th>{"".join(f"<th>{html.escape(label)}</th>" for label in quick_columns)}</tr></thead><tbody>{"".join(model_rows) or "<tr><td>暂无汇总数据</td></tr>"}</tbody></table></div><p class="footnote">{quick_note}</p></section>'
                  if quick_columns else "")

    return f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Strata Benchmark 截图概览 · {html.escape(run_date)}</title>
<style>
:root{{--ink:#172033;--muted:#596579;--line:#d9e0ea;--paper:#fff;--bg:#eef2f7;--blue:#245fc7;--teal:#087e78;--amber:#9b5b08;--green:#176b45;--red:#a53b3b}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 "Segoe UI","Microsoft YaHei",sans-serif}}
main{{max-width:1440px;margin:0 auto;padding:20px 24px 40px}}h1{{font-size:25px;margin:0}}h2{{font-size:17px;margin:0 0 12px}}p{{margin:0}}small,.muted{{color:var(--muted);font-size:12px}}header{{display:flex;align-items:center;gap:12px;margin-bottom:12px}}.badge{{border-radius:999px;padding:4px 10px;font-weight:700;font-size:12px}}.good{{background:#e2f3ea;color:var(--green)}}.warn{{background:#fff0d9;color:var(--amber)}}
.run-meta,.hardware,.panel{{background:var(--paper);border:1px solid var(--line);border-radius:12px}}.run-meta{{padding:11px 14px;margin-bottom:8px;display:flex;flex-wrap:wrap;gap:8px 18px}}.run-meta b{{color:var(--ink)}}.hardware{{padding:10px 14px;margin-bottom:14px;display:flex;flex-wrap:wrap;gap:6px 18px;font-size:13px}}.hardware span{{white-space:nowrap}}.hardware strong{{font-weight:650}}
.grid{{display:grid;grid-template-columns:1fr;gap:14px;align-items:start}}.panel{{padding:15px;margin-bottom:14px;min-width:0}}.panel-title{{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin-bottom:10px}}.panel-title p{{color:var(--muted);font-size:12px}}.table-wrap{{overflow-x:auto}}table{{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}}th,td{{text-align:left;vertical-align:top;padding:9px 8px;border-bottom:1px solid #e8ecf2}}thead th{{font-size:11px;color:var(--muted);font-weight:650;white-space:nowrap}}tbody th{{font-size:12px;min-width:150px}}.metric-cell{{min-width:112px}}.metric-cell strong{{font-size:18px;white-space:nowrap}}.metric-cell small{{display:block;white-space:nowrap;margin-top:3px}}.mini-track{{display:block;height:5px;background:#e8edf5;border-radius:9px;margin:5px 0}}.mini-track i{{display:block;height:100%;background:var(--blue);border-radius:9px}}.context-table{{min-width:680px}}
.load-table{{min-width:620px}}.load-table td{{white-space:nowrap}}.load-table td b{{display:block;font-size:14px}}.load-table td small{{display:block}}.callout{{border-left:3px solid var(--amber);background:#fff8eb;color:#75480c;padding:9px 11px;border-radius:4px;font-size:12px;margin:0 0 10px}}.load-key{{display:flex;gap:15px;flex-wrap:wrap;color:var(--muted);font-size:11px;margin-top:9px}}.dot{{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--teal);margin-right:5px}}
.score-table td{{white-space:nowrap}}.score-table td small{{display:block;white-space:normal}}.footnote{{font-size:11px;color:var(--muted);margin-top:8px}}.share-note{{font-size:11px;color:var(--muted);margin-top:12px;padding-top:9px;border-top:1px solid var(--line)}}.share-actions{{display:flex;gap:12px;align-items:center;margin:0 0 14px}}.share-actions button,.share-preview button{{border:0;border-radius:7px;background:#245fc7;color:white;padding:9px 14px;font-weight:650}}.share-actions a{{color:#245fc7}}#share-status{{font-size:12px;color:var(--muted)}}.share-art{{position:fixed;left:-20000px;top:0;width:1600px;height:auto;pointer-events:none}}.share-preview{{position:fixed;inset:0;z-index:10;background:#101828dd;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:20px}}.share-preview[hidden]{{display:none}}.share-preview img{{max-width:min(96vw,1400px);max-height:82vh;object-fit:contain;background:white;border-radius:8px}}.share-preview>div{{display:flex;gap:10px}}#close-share-preview{{background:#596579}}@media(max-width:960px){{main{{padding:14px}}.grid{{grid-template-columns:1fr}}header{{align-items:flex-start}}h1{{font-size:22px}}}}@media print{{body{{background:#fff}}main{{max-width:none;padding:10mm}}.panel,.hardware,.run-meta{{break-inside:avoid;box-shadow:none}}.share-actions{{display:none}}}}
</style></head><body><main>
<header><h1>Strata Benchmark · 截图概览</h1><span class="badge {state_class}">{html.escape(status_label)}</span><span class="muted">{html.escape(run_date)} · {records} 条记录</span></header>
<div class="run-meta">{''.join(meta_items)}</div>
<div class="hardware"><span><strong>GPU</strong> {html.escape(gpu_label)}</span>{power_html}<span><strong>CPU</strong> {html.escape(cpu)}{html.escape(core_label)}</span><span><strong>RAM</strong> {_fmt(ram_gib)} GiB</span><span><strong>系统</strong> {html.escape(str(hardware.get('platform') or '未获取'))}</span>{f'<span><strong>驱动</strong> {html.escape(driver)}</span>' if driver else ''}</div>
{share_controls}
<div class="grid">{performance_html}{load_html}</div>
{capacity_html}
{quick_html}
<p class="share-note">点击“导出分享 PNG”会优先复制图片；若浏览器权限不允许，将显示图片并提供下载。本页只展示已选项目的对照摘要；阶段完整性、失败详情和逐项记录见<a href="report.html">完整报告</a>。保存的 HTML 是生成时的静态快照，更新模板后需重新生成报告。</p>
<script>{share_script}</script>
</main></body></html>"""


def render_report_preview(run_dir: Path) -> str:
    """Write an isolated screenshot-first overview without replacing the full report."""
    summary = build_summary(run_dir)
    output = Path(run_dir) / "report-preview.html"
    share_svg = render_share_svg(summary)
    output.write_text(_html_overview_preview(summary, share_svg), encoding="utf-8")
    (Path(run_dir) / "share.svg").write_text(share_svg, encoding="utf-8")
    return str(output)

