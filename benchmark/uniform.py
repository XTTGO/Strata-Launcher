"""Report-local benchmark conditions without rewriting model-specific tuning."""

from __future__ import annotations

import copy
from typing import Any


# These affect the available KV and VRAM resources in every measured request.
# Model-specific throughput tuning stays at its source profile value.
COMMON_OPTIONS = {
    "--kv": "int8",
    "--kv-resident": "32768",
    "--vram-reserve-mib": "3072",
}

# Only measurement conditions and side-effecting profile writes are reset.
RESET_OPTIONS = frozenset(COMMON_OPTIONS) | {
    "--vision",
    "--batch", "--slots", "--batch-groups", "--batch-mtp",
    "--prompt-cache", "--prompt-cache-every", "--prompt-cache-root", "--prompt-cache-tail",
    "--conversation-cache-mib", "--conversation-cache-slots",
    "--expert-profile-save",
}
COMPARISON_OPTIONS = frozenset(COMMON_OPTIONS) | {"--prompt-cache"}


def _options(args: list[str]) -> dict[str, str | None]:
    result: dict[str, str | None] = {}
    index = 0
    while index < len(args):
        flag = args[index]
        if not flag.startswith("--"):
            raise ValueError(f"无法解释的引擎参数：{flag}")
        if flag in result:
            raise ValueError(f"重复的引擎参数：{flag}")
        value = args[index + 1] if index + 1 < len(args) and not args[index + 1].startswith("--") else None
        result[flag] = value
        index += 2 if value is not None else 1
    return result


def normalize_uniform_config(config: dict[str, Any], *, phase: str, slots: int) -> dict[str, Any]:
    """Preserve source tuning while controlling the stage's resource/cache policy."""
    if phase not in {"solo", "cache", "load"}:
        raise ValueError(f"未知统一测试阶段：{phase}")
    if not 1 <= slots <= 8:
        raise ValueError("统一测试并发槽数必须在 1 到 8 之间")
    if config.get("arch") == "qwen35moe":
        raise ValueError("Qwen3.6 独立引擎暂不支持统一配置模式")
    normalized = copy.deepcopy(config)
    options = _options([str(value) for value in normalized.get("args") or []])
    for key in RESET_OPTIONS:
        options.pop(key, None)
    options.update(COMMON_OPTIONS)
    options["--prompt-cache"] = "6" if phase == "cache" else "0"
    normalized["args"] = [part for flag, value in options.items() for part in ([flag] if value is None else [flag, value])]
    normalized.pop("vision", None)
    normalized["parallel"] = slots if phase == "load" else 1
    return normalized


def _signature(config: dict[str, Any]) -> dict[str, Any]:
    options = _options([str(value) for value in config.get("args") or []])
    return {"args": {key: options.get(key) for key in COMPARISON_OPTIONS},
            "parallel": config.get("parallel"), "vision": config.get("vision")}


def validate_uniform_compatibility(configs: list[dict[str, Any]]) -> None:
    """Refuse differences in benchmark-controlled conditions only."""
    if not configs:
        raise ValueError("没有可比较的模型配置")
    expected = _signature(configs[0])
    for index, config in enumerate(configs[1:], 2):
        actual = _signature(config)
        if actual != expected:
            changed = sorted(key for key in COMPARISON_OPTIONS
                             if expected["args"][key] != actual["args"][key])
            if not changed:
                changed = ["parallel / vision"]
            raise ValueError(f"第 {index} 个模型仍有未统一的测试条件：{', '.join(changed)}")
