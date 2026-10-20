"""Launcher-owned near-capacity recall probe and its evidence judgement."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from .storage import is_cancelled
from .workloads import _corpus


def judge_capacity(rows: list[dict[str, Any]], cap: int) -> dict[str, Any]:
    expected = {(depth, repetition) for depth in (10, 50, 90) for repetition in (1, 2)}
    observed = {(row.get("depth"), row.get("repetition")) for row in rows}
    tokens = [int(row["prompt_tokens"]) for row in rows if isinstance(row.get("prompt_tokens"), int)]
    reasons: list[str] = []
    if len(rows) != 6 or observed != expected:
        reasons.append("六个位置/重复样本不完整")
    if any(row.get("status") != "success" for row in rows):
        reasons.append("请求失败或中止")
    if len(tokens) != 6 or any(value < int(cap * 0.9) for value in tokens):
        reasons.append("真实输入 token 未达到档位的 90%")
    if any(row.get("finish_reason") != "stop" for row in rows):
        reasons.append("生成未正常结束")
    if reasons:
        status = "insufficient"
    elif any(not row.get("found") for row in rows):
        status = "failed"
        reasons.append("前/中/后位置的信息召回未全部命中")
    else:
        status = "verified"
    return {
        "status": status,
        "passed": status == "verified",
        "hits": sum(bool(row.get("found")) for row in rows),
        "cases": len(rows),
        "actual_prompt_tokens_min": min(tokens) if tokens else None,
        "actual_prompt_tokens_max": max(tokens) if tokens else None,
        "reasons": reasons,
    }


def _probe_text(source: str, cap: int, depth: int, secret: str, multiplier: float) -> str:
    target_chars = int(cap * 3.2 * multiplier)
    filler = (source * (target_chars // len(source) + 1))[:target_chars]
    cut = int(len(filler) * depth / 100)
    cut = filler.rfind("\n", 0, cut) + 1 or cut
    return (
        filler[:cut] + f"\nSECRET-CODE: {secret}\n" + filler[cut:]
        + "\n\n请只回答上文 SECRET-CODE 的值，不要解释。"
    )


def run_capacity_probe(
    client: Any, server: Any, dirs: Any, root: Path, round_number: int, run_id: str, cap: int
) -> list[dict[str, Any]]:
    """Six fresh 10/50/90% recall requests near one configured context cap."""
    source = _corpus(root)
    dirs.prompts.mkdir(parents=True, exist_ok=True)
    dirs.answers.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    for depth in (10, 50, 90):
        for repetition in (1, 2):
            if is_cancelled(dirs):
                return rows
            digest = hashlib.sha256(f"{run_id}:{cap}:{depth}:{repetition}".encode()).hexdigest()[:12].upper()
            secret = f"CAP-{digest}"
            basename = f"capacity-{server.snapshot.model_id}-{cap // 1024}k-d{depth}-r{repetition}"
            prompt_file = dirs.prompts / f"{basename}.txt"
            answer_file = dirs.answers / f"{basename}.txt"
            token_count: int | None = None
            answer = ""
            finish_reason: str | None = None
            wall_seconds: float | None = None
            error: str | None = None
            sample_index = len(server.sampler.samples)
            multiplier = 0.94
            for attempt in range(1, 5):
                prompt = _probe_text(source, cap, depth, secret, multiplier)
                prompt_file.write_text(prompt, encoding="utf-8")
                try:
                    response, wall_seconds = client.chat({
                        "model": "strata", "messages": [{"role": "user", "content": prompt}],
                        "max_tokens": 40, "temperature": 0, "stream": False,
                        "cache_prompt": False, "reasoning_effort": "none",
                        "chat_template_kwargs": {"enable_thinking": False},
                    })
                    choices = response.get("choices") or []
                    choice = choices[0] if choices else {}
                    answer = str((choice.get("message") or {}).get("content") or "")
                    finish_reason = choice.get("finish_reason")
                    token_count = (response.get("usage") or {}).get("prompt_tokens")
                    if not isinstance(token_count, int):
                        error = "服务未返回真实 prompt token 数"
                        break
                    if token_count >= int(cap * 0.9):
                        break
                    multiplier = min(1.2, multiplier * 1.08)
                except Exception as exc:
                    message = str(exc).lower()
                    if attempt < 4 and any(term in message for term in (
                        "context length", "context window", "too many tokens", "上下文", "超出上下文"
                    )):
                        multiplier *= 0.94
                        continue
                    error = f"{type(exc).__name__}: {exc}"
                    break
            answer_file.write_text(answer, encoding="utf-8")
            row = {
                "run_id": run_id,
                "model_id": server.snapshot.model_id,
                "model_name": server.snapshot.model_name,
                "config_snapshot": str(server.snapshot.path),
                "round": round_number,
                "stage": "capacity",
                "case_id": f"capacity-{cap // 1024}k-d{depth}-r{repetition}",
                "context_tier": cap,
                "depth": depth,
                "repetition": repetition,
                "status": "failure" if error else "success" if token_count is not None and token_count >= int(cap * 0.9) else "insufficient",
                "found": secret in answer,
                "prompt_tokens": token_count,
                "finish_reason": finish_reason,
                "wall_seconds": wall_seconds,
                "prompt_file": str(prompt_file),
                "answer_file": str(answer_file),
                "attempts": attempt,
                "error": error,
                **server.sampler.summary(sample_index),
            }
            rows.append(row)
            if error:
                return rows
    return rows
