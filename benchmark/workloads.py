from __future__ import annotations

import json
import math
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .processes import OwnedServer
from .storage import RunDirectories, is_cancelled


@dataclass(frozen=True)
class PerformanceCase:
    case_id: str
    label: str
    target_tokens: int
    max_tokens: int = 256


@dataclass(frozen=True)
class CacheCase:
    case_id: str = "cache-32k"
    target_tokens: int = 32768
    max_tokens: int = 128


class StrataClient:
    def __init__(self, port: int, timeout: int = 1800):
        self.base = f"http://127.0.0.1:{int(port)}"
        self.timeout = timeout

    def get_json(self, path: str, timeout: int = 10) -> dict[str, Any]:
        with urllib.request.urlopen(self.base + path, timeout=timeout) as response:
            data = json.loads(response.read().decode("utf-8-sig"))
        if not isinstance(data, dict):
            raise ValueError(f"{path} 返回的不是 JSON object")
        return data

    def count_tokens(self, content: str) -> int:
        body = {"model": "strata", "messages": [{"role": "user", "content": content}],
                "thinking": {"type": "disabled"}}
        request = urllib.request.Request(
            self.base + "/v1/messages/count_tokens",
            data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            result = json.loads(response.read().decode("utf-8-sig"))
        count = result.get("input_tokens") if isinstance(result, dict) else None
        if not isinstance(count, int) or count <= 0:
            raise RuntimeError("模型 tokenizer 未返回有效输入 token 数")
        return count

    def chat(self, body: dict[str, Any]) -> tuple[dict[str, Any], float]:
        request = urllib.request.Request(
            self.base + "/v1/chat/completions",
            data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        started = time.perf_counter()
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            excerpt = exc.read().decode("utf-8", "replace")[:2000]
            raise RuntimeError(f"HTTP {exc.code}: {excerpt}") from exc
        elapsed = time.perf_counter() - started
        try:
            data = json.loads(raw.decode("utf-8-sig"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"API 返回无法解析的 JSON：{raw[:1000]!r}") from exc
        if not isinstance(data, dict):
            raise RuntimeError("API 返回的 JSON 根节点不是 object")
        return data, elapsed


def server_max_context(client: StrataClient, fallback: int = 0) -> int:
    for path in ("/metrics", "/props"):
        try:
            data = client.get_json(path)
            candidates = [
                (data.get("engine") or {}).get("max_context") if isinstance(data.get("engine"), dict) else None,
                data.get("max_context"),
                data.get("n_ctx"),
            ]
            for value in candidates:
                if value:
                    return int(value)
        except (OSError, ValueError, TypeError, urllib.error.URLError):
            continue
    return int(fallback)


def configured_max_context(server: OwnedServer) -> int:
    args = [str(x) for x in server.snapshot.config.get("args", [])]
    try:
        index = args.index("--max-context")
        return int(args[index + 1])
    except (ValueError, IndexError, TypeError):
        return 0


def _corpus(root: Path) -> str:
    files = [root / "README.md", root / "docs" / "DETAILS.md", root / "docs" / "AI_SETUP.md"]
    parts: list[str] = []
    for path in files:
        try:
            parts.append(f"\n\n=== {path.name} ===\n" + path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            pass
    if not parts:
        raise RuntimeError("无法从 Strata 本地文档生成 Benchmark Prompt")
    return "".join(parts)


def build_prompt(root: Path, dirs: RunDirectories, target_tokens: int, label: str) -> tuple[str, Path]:
    path = dirs.prompts / f"prompt-{label.lower()}.txt"
    if path.exists():
        return path.read_text(encoding="utf-8"), path
    source = _corpus(root)
    target_chars = max(1000, int(target_tokens * 3.2))
    repeated = (source * (target_chars // len(source) + 1))[:target_chars]
    prompt = repeated + "\n\n请用三句话总结上面的资料。"
    path.write_text(prompt, encoding="utf-8")
    return prompt, path


def build_measured_prompt(root: Path, dirs: RunDirectories, client: StrataClient,
                          target_tokens: int, label: str, model_id: str, prefix: str = "") -> tuple[str, Path]:
    """Fit each model's prompt with its serving tokenizer before measured inference."""
    source = _corpus(root)
    suffix = "\n\n请用三句话总结上面的资料。"
    length = max(1000, int(target_tokens * 3.2))
    for _ in range(5):
        prompt = (source * (length // len(source) + 1))[:length] + suffix
        actual = client.count_tokens(prefix + prompt)
        if abs(actual - target_tokens) <= target_tokens * 0.005:
            path = dirs.prompts / f"prompt-{model_id}-{label.lower()}.txt"
            path.write_text(prompt, encoding="utf-8")
            return prompt, path
        length = max(1000, int(length * target_tokens / actual))
    raise RuntimeError(f"{model_id} 的 {label} 提示词无法校准到 {target_tokens} tokens")


def _message(response: dict[str, Any]) -> dict[str, Any]:
    choices = response.get("choices") or []
    if not choices or not isinstance(choices[0], dict):
        return {}
    msg = choices[0].get("message") or {}
    return msg if isinstance(msg, dict) else {}


def _timing_fields(response: dict[str, Any], wall_s: float) -> dict[str, Any]:
    timings = response.get("timings") or {}
    usage = response.get("usage") or {}
    cached = timings.get("cache_n")
    if cached is None:
        cached = timings.get("prompt_n_cached", timings.get("prompt_cached_n"))
    if cached is None:
        cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", usage.get("prompt_tokens_cached"))
    fresh = timings.get("prompt_n")
    prompt_total = usage.get("prompt_tokens")
    if prompt_total is None and fresh is not None:
        prompt_total = int(fresh) + int(cached or 0)
    if fresh is None and prompt_total is not None and cached is not None:
        fresh = max(0, int(prompt_total) - int(cached))
    prompt_ms = timings.get("prompt_ms")
    draft_n = timings.get("draft_n")
    accepted = timings.get("draft_n_accepted")
    return {
        "wall_seconds": round(wall_s, 4),
        "prompt_tokens": prompt_total,
        "reused_prompt_tokens": cached,
        "new_prompt_tokens": fresh,
        "completion_tokens": timings.get("predicted_n", usage.get("completion_tokens")),
        "prompt_ms": prompt_ms,
        "prefill_seconds": round(float(prompt_ms) / 1000, 4) if prompt_ms is not None else None,
        "prompt_tokens_per_second": timings.get("prompt_per_second"),
        "decode_tokens_per_second": timings.get("predicted_per_second"),
        "draft_tokens": draft_n,
        "draft_accepted": accepted,
        "draft_acceptance": (float(accepted) / float(draft_n)) if draft_n else None,
    }


def _output_problem(response: dict[str, Any], metrics: dict[str, Any], *, require_speed: bool = False) -> str | None:
    if not str(_message(response).get("content") or "").strip():
        return "服务未返回有效输出内容"
    count = metrics.get("completion_tokens")
    if not isinstance(count, int) or count <= 0:
        return "服务未返回有效输出 token 数"
    if require_speed:
        for key in ("prompt_tokens_per_second", "decode_tokens_per_second"):
            value = metrics.get(key)
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                return "服务未返回有效速度指标"
    return None


def run_performance(
    client: StrataClient,
    server: OwnedServer,
    dirs: RunDirectories,
    root: Path,
    case: PerformanceCase,
    round_number: int,
    repetition: int,
    run_id: str,
) -> dict[str, Any]:
    max_context = server_max_context(client, configured_max_context(server))
    if max_context and case.target_tokens + case.max_tokens + 64 > max_context:
        return {
            "run_id": run_id,
            "model_id": server.snapshot.model_id,
            "config_snapshot": str(server.snapshot.path),
            "round": round_number,
            "stage": "performance",
            "case_id": case.case_id,
            "repetition": repetition,
            "status": "skipped",
            "skip_reason": "context_limit",
            "target_tokens": case.target_tokens,
            "server_max_context": max_context,
        }
    nonce = f"[strata-benchmark {run_id} {server.snapshot.model_id} r{round_number} n{repetition}]\n"
    prompt, prompt_path = build_measured_prompt(root, dirs, client, case.target_tokens,
                                                 case.label, server.snapshot.model_id, prefix=nonce)
    body = {
        "model": "strata",
        "messages": [{"role": "user", "content": nonce + prompt}],
        "max_tokens": case.max_tokens,
        "temperature": 0,
        "seed": 1,
        "stream": False,
        "cache_prompt": False,
        "reasoning_effort": "none",
        "chat_template_kwargs": {"enable_thinking": False},
    }
    sample_index = len(server.sampler.samples)
    response, wall_s = client.chat(body)
    msg = _message(response)
    metrics = _timing_fields(response, wall_s)
    cached = metrics["reused_prompt_tokens"]
    prompt_total = metrics["prompt_tokens"]
    problem = _output_problem(response, metrics, require_speed=True)
    if not problem and cached is None:
        problem = "冷输入缺少服务端缓存复用计数"
    elif not problem and int(cached) != 0:
        problem = f"冷输入复用了 {cached} tokens"
    elif not problem and not isinstance(prompt_total, int):
        problem = "性能输入缺少服务端实测 token 数"
    elif not problem and not case.target_tokens * 0.95 <= prompt_total <= case.target_tokens * 1.05:
        problem = f"性能输入实测 {prompt_total} tokens，偏离所选目标 {case.target_tokens} 超过 5%"
    answer_path = dirs.answers / server.snapshot.model_id / f"round-{round_number}"
    answer_path.mkdir(parents=True, exist_ok=True)
    answer_file = answer_path / f"{case.case_id}-rep-{repetition}.txt"
    answer_file.write_text(str(msg.get("content") or ""), encoding="utf-8")
    return {
        "run_id": run_id,
        "model_id": server.snapshot.model_id,
        "model_name": server.snapshot.model_name,
        "config_snapshot": str(server.snapshot.path),
        "round": round_number,
        "stage": "performance",
        "case_id": case.case_id,
        "repetition": repetition,
        "status": "failure" if problem else "success",
        **({"error": problem} if problem else {}),
        "target_tokens": case.target_tokens,
        "server_max_context": max_context,
        "prompt_file": str(prompt_path),
        "answer_file": str(answer_file),
        **metrics,
        **server.sampler.summary(sample_index),
    }


def warm_up(client: StrataClient) -> dict[str, Any]:
    response, wall_s = client.chat(
        {
            "model": "strata",
            "messages": [{"role": "user", "content": "Reply with the word ready."}],
            "max_tokens": 16,
            "temperature": 0,
            "stream": False,
            "cache_prompt": False,
            "reasoning_effort": "none",
            "chat_template_kwargs": {"enable_thinking": False},
        }
    )
    return {"status": "success", "excluded_from_summary": True, **_timing_fields(response, wall_s)}


def run_cache_sequence(
    client: StrataClient,
    server: OwnedServer,
    dirs: RunDirectories,
    root: Path,
    case: CacheCase,
    round_number: int,
    run_id: str,
) -> list[dict[str, Any]]:
    prompt, prompt_path = build_measured_prompt(root, dirs, client, case.target_tokens,
                                                "32k-cache", server.snapshot.model_id)
    initial_message = prompt + "\n列出资料中的三个主题。"
    prompt_path.write_text(initial_message, encoding="utf-8")
    messages: list[dict[str, Any]] = [{"role": "user", "content": initial_message}]
    followups = [None, "针对第二个主题给出两个关键点。", "最后用一句话说明三个主题的联系。"]
    records: list[dict[str, Any]] = []
    for turn, followup in enumerate(followups, 1):
        if is_cancelled(dirs):
            break
        if followup:
            messages.append({"role": "user", "content": followup})
        sample_index = len(server.sampler.samples)
        response, wall_s = client.chat(
            {
                "model": "strata",
                "messages": messages,
                "max_tokens": case.max_tokens,
                "temperature": 0,
                "seed": 1,
                "stream": False,
                "cache_prompt": True,
                "reasoning_effort": "none",
                "chat_template_kwargs": {"enable_thinking": False},
            }
        )
        msg = _message(response)
        content = str(msg.get("content") or "")
        messages.append({"role": "assistant", "content": content})
        answer_dir = dirs.answers / server.snapshot.model_id / f"round-{round_number}"
        answer_dir.mkdir(parents=True, exist_ok=True)
        answer_file = answer_dir / f"{case.case_id}-turn-{turn}.txt"
        answer_file.write_text(content, encoding="utf-8")
        fields = _timing_fields(response, wall_s)
        problem = _output_problem(response, fields)
        actual_tokens = fields["prompt_tokens"]
        reused_tokens = fields["reused_prompt_tokens"]
        if not problem and turn == 1:
            if not isinstance(actual_tokens, int) or not case.target_tokens * 0.95 <= actual_tokens <= case.target_tokens * 1.05:
                problem = f"缓存输入实测 {actual_tokens} tokens，偏离所选目标 {case.target_tokens} 超过 5%"
            elif not isinstance(reused_tokens, int):
                problem = "缓存测试缺少服务端复用 token 计数"
            elif reused_tokens > case.target_tokens * 0.01:
                problem = f"缓存测试首轮已复用 {reused_tokens} tokens，超过输入目标的 1%"
        elif not problem and (not isinstance(reused_tokens, int) or reused_tokens < case.target_tokens * 0.4):
            problem = f"缓存复用不足：实测 {reused_tokens} tokens，低于首轮目标的 40%"
        records.append(
            {
                "run_id": run_id,
                "model_id": server.snapshot.model_id,
                "model_name": server.snapshot.model_name,
                "config_snapshot": str(server.snapshot.path),
                "round": round_number,
                "stage": "cache",
                "case_id": case.case_id,
                "turn": turn,
                "status": "failure" if problem else "success",
                **({"error": problem} if problem else {}),
                "target_tokens": case.target_tokens,
                "prompt_file": str(prompt_path),
                "answer_file": str(answer_file),
                **fields,
                **server.sampler.summary(sample_index),
            }
        )
    return records


def run_stability(
    client: StrataClient,
    server: OwnedServer,
    dirs: RunDirectories,
    round_number: int,
    run_id: str,
    count: int = 10,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for index in range(1, count + 1):
        if is_cancelled(dirs):
            break
        sample_index = len(server.sampler.samples)
        response, wall_s = client.chat(
            {
                "model": "strata",
                "messages": [{"role": "user", "content": f"[stability {run_id}-{index}] 用两句话解释缓存命中率。"}],
                "max_tokens": 96,
                "temperature": 0,
                "stream": False,
                "cache_prompt": False,
                "reasoning_effort": "none",
                "chat_template_kwargs": {"enable_thinking": False},
            }
        )
        fields = _timing_fields(response, wall_s)
        problem = _output_problem(response, fields)
        rows.append(
            {
                "run_id": run_id,
                "model_id": server.snapshot.model_id,
                "model_name": server.snapshot.model_name,
                "config_snapshot": str(server.snapshot.path),
                "round": round_number,
                "stage": "stability",
                "case_id": "sequential-short",
                "iteration": index,
                "status": "failure" if problem else "success",
                **({"error": problem} if problem else {}),
                **fields,
                **server.sampler.summary(sample_index),
            }
        )
    return rows

