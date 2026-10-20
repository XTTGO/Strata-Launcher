from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .processes import OwnedServer
from .storage import RunDirectories
from .workloads import StrataClient, _message, _timing_fields


@dataclass(frozen=True)
class AgentCase:
    case_id: str
    category: str
    preset: str
    prompt: str
    assertions: list[dict[str, Any]]
    reasoning_effort: str = "medium"
    max_tokens: int = 256
    tools: list[dict[str, Any]] | None = None
    messages: list[dict[str, Any]] | None = None


def load_cases(path: Path, preset: str) -> list[AgentCase]:
    raw = json.loads(path.read_text(encoding="utf-8-sig"))
    cases = []
    for item in raw.get("cases", []):
        membership = str(item.get("preset", "standard"))
        if preset == "standard" and membership != "standard":
            continue
        cases.append(
            AgentCase(
                case_id=str(item["id"]),
                category=str(item["category"]),
                preset=membership,
                prompt=str(item.get("prompt", "")),
                assertions=list(item.get("assertions", [])),
                reasoning_effort=str(item.get("reasoning_effort", "medium")),
                max_tokens=int(item.get("max_tokens", 256)),
                tools=item.get("tools"),
                messages=item.get("messages"),
            )
        )
    return cases


def _json_from_text(text: str) -> Any:
    stripped = text.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if len(lines) >= 3:
            stripped = "\n".join(lines[1:-1])
            if stripped.lstrip().lower().startswith("json\n"):
                stripped = stripped.lstrip()[5:]
    return json.loads(stripped)


def _tool_calls(message: dict[str, Any]) -> list[dict[str, Any]]:
    calls = message.get("tool_calls") or []
    return calls if isinstance(calls, list) else []


def score_assertion(assertion: dict[str, Any], text: str, message: dict[str, Any]) -> dict[str, Any]:
    kind = str(assertion.get("type"))
    expected = assertion.get("expected")
    observed: Any = None
    passed = False
    try:
        if kind == "json_required":
            value = _json_from_text(text)
            required = list(assertion.get("keys", []))
            observed = sorted(value.keys()) if isinstance(value, dict) else type(value).__name__
            passed = isinstance(value, dict) and all(key in value for key in required)
        elif kind == "json_value":
            value = _json_from_text(text)
            key = str(assertion["key"])
            observed = value.get(key) if isinstance(value, dict) else None
            passed = observed == expected
        elif kind == "required_strings":
            required = [str(x) for x in assertion.get("values", [])]
            observed = [x for x in required if x in text]
            passed = len(observed) == len(required)
        elif kind == "forbidden_strings":
            forbidden = [str(x) for x in assertion.get("values", [])]
            observed = [x for x in forbidden if x in text]
            passed = not observed
        elif kind == "regex":
            observed = re.findall(str(assertion["pattern"]), text, flags=re.I | re.M)
            passed = bool(observed)
        elif kind == "tool_call":
            calls = _tool_calls(message)
            name = str(assertion["name"])
            matched = []
            for call in calls:
                fn = call.get("function") or {}
                if fn.get("name") == name:
                    args = fn.get("arguments", "{}")
                    if isinstance(args, str):
                        args = json.loads(args)
                    matched.append(args)
            observed = matched
            required_args = assertion.get("arguments", {})
            passed = any(all(args.get(k) == v for k, v in required_args.items()) for args in matched if isinstance(args, dict))
        elif kind == "reasoning_empty":
            observed = message.get("reasoning_content")
            passed = not observed
        else:
            observed = f"unknown scorer: {kind}"
    except Exception as exc:  # scorer failures are evidence, not runner failures
        observed = f"scorer error: {exc}"
        passed = False
    return {"type": kind, "expected": expected if expected is not None else assertion, "observed": observed, "passed": passed}


def run_agent_case(
    client: StrataClient,
    server: OwnedServer,
    dirs: RunDirectories,
    case: AgentCase,
    round_number: int,
    run_id: str,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": "strata",
        "messages": case.messages or [{"role": "user", "content": case.prompt}],
        "max_tokens": case.max_tokens,
        "temperature": 0,
        "seed": 7,
        "stream": False,
        "cache_prompt": False,
        "reasoning_effort": case.reasoning_effort,
        "chat_template_kwargs": {"enable_thinking": case.reasoning_effort != "none"},
    }
    if case.tools:
        body["tools"] = case.tools
        body["tool_choice"] = "auto"
    sample_index = len(server.sampler.samples)
    response, wall_s = client.chat(body)
    message = _message(response)
    content = str(message.get("content") or "")
    assertions = [score_assertion(a, content, message) for a in case.assertions]
    answer_dir = dirs.answers / server.snapshot.model_id / f"round-{round_number}" / "agent"
    answer_dir.mkdir(parents=True, exist_ok=True)
    answer_file = answer_dir / f"{case.case_id}.json"
    answer_file.write_text(json.dumps(message, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {
        "run_id": run_id,
        "model_id": server.snapshot.model_id,
        "model_name": server.snapshot.model_name,
        "config_snapshot": str(server.snapshot.path),
        "round": round_number,
        "stage": "agent",
        "case_id": case.case_id,
        "category": case.category,
        "status": "success",
        "passed": bool(assertions) and all(item["passed"] for item in assertions),
        "assertions": assertions,
        "answer_file": str(answer_file),
        **_timing_fields(response, wall_s),
        **server.sampler.summary(sample_index),
    }

