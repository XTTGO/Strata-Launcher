from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class RuntimePaths:
    root: Path
    launcher: Path
    python: Path
    server: Path
    reports: Path


@dataclass(frozen=True)
class ModelProfile:
    model_id: str
    model_name: str
    config_path: Path
    config_hash: str
    config_bytes: bytes
    config: dict[str, Any]
    port: int


@dataclass(frozen=True)
class ConfigSnapshot:
    model_id: str
    model_name: str
    source_path: Path
    source_hash: str
    path: Path
    config: dict[str, Any]
    port: int


def runtime_paths(root: Path | None = None) -> RuntimePaths:
    launcher = Path(__file__).resolve().parents[1]
    candidate = launcher.parent
    if root is None and not (candidate / "START-HERE.bat").is_file() and (candidate / "Strata" / "START-HERE.bat").is_file():
        candidate /= "Strata"
    strata_root = (root or candidate).resolve()
    return RuntimePaths(
        root=strata_root,
        launcher=launcher,
        python=strata_root / ".venv" / "Scripts" / "python.exe",
        server=strata_root / "serve" / "server.py",
        reports=launcher / "reports",
    )


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _safe_id(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip()).strip("-.")
    return value.lower() or "model"


def _load_config(path: Path) -> tuple[bytes, dict[str, Any]]:
    raw = path.read_bytes()
    # utf-8-sig accepts both ordinary UTF-8 and BOM files.
    data = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(data, dict):
        raise ValueError("configuration root is not an object")
    return raw, data


def is_qwen36_own_path(config: dict[str, Any]) -> bool:
    return config.get("arch") == "qwen35moe"


def discover_profiles(root: Path) -> list[ModelProfile]:
    profiles: list[ModelProfile] = []
    used_ids: set[str] = set()
    for path in sorted(root.glob("strata-*.json"), key=lambda p: p.name.lower()):
        if path.name.lower().endswith(".shared-settings.json"):
            continue
        try:
            raw, data = _load_config(path)
            if not data.get("exe") or not isinstance(data.get("args"), list) or not data.get("model_name"):
                continue
            # The config stem is stable and keeps deeply nested Windows report paths short.
            base = _safe_id(path.stem)
            model_id = base
            suffix = 2
            while model_id in used_ids:
                model_id = f"{base}-{suffix}"
                suffix += 1
            used_ids.add(model_id)
            profiles.append(
                ModelProfile(
                    model_id=model_id,
                    model_name=str(data["model_name"]),
                    config_path=path.resolve(),
                    config_hash=_sha256(raw),
                    config_bytes=raw,
                    config=data,
                    port=int(data.get("port", 8080)),
                )
            )
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            continue
    return profiles


def revalidate_profile(profile: ModelProfile) -> None:
    current = profile.config_path.read_bytes()
    if _sha256(current) != profile.config_hash:
        raise RuntimeError(f"模型配置在测试准备期间发生变化：{profile.config_path}")


def _set_arg(args: list[str], flag: str, value: str | None) -> None:
    try:
        idx = args.index(flag)
    except ValueError:
        idx = -1
    if value is None:
        if idx >= 0:
            del args[idx : min(idx + 2, len(args))]
        return
    if idx >= 0:
        if idx + 1 < len(args):
            args[idx + 1] = str(value)
        else:
            args.append(str(value))
    else:
        args.extend([flag, str(value)])


def _without_profile_save(args: list[str]) -> list[str]:
    safe: list[str] = []
    index = 0
    while index < len(args):
        item = args[index]
        if item == "--expert-profile-save":
            index += 2
        elif item.startswith("--expert-profile-save="):
            index += 1
        else:
            safe.append(item)
            index += 1
    return safe


def snapshot_profile(
    profile: ModelProfile,
    configs_dir: Path,
    port: int,
    round_number: int,
    overrides: dict[str, str | None] | None = None,
    variant_id: str | None = None,
    *,
    uniform_phase: str | None = None,
    uniform_slots: int = 1,
) -> ConfigSnapshot:
    revalidate_profile(profile)
    config = json.loads(profile.config_bytes.decode("utf-8-sig"))
    if uniform_phase is not None:
        from .uniform import normalize_uniform_config
        config = normalize_uniform_config(config, phase=uniform_phase, slots=uniform_slots)
    config["port"] = int(port)
    args = _without_profile_save([str(x) for x in config.get("args", [])])
    if overrides and "--max-context" in overrides and uniform_phase is not None:
        # A selected context tier replaces the source tier's YaRN settings. With no
        # selected tier, retain the source model's complete context configuration.
        for flag in ("--rope-scaling", "--rope-scale", "--yarn-orig-ctx"):
            _set_arg(args, flag, None)
    if is_qwen36_own_path(config):
        forbidden = {"--kv", "--kv-resident", "--rope-scaling", "--rope-scale", "--yarn-orig-ctx", "--vision"}
        if forbidden.intersection(overrides or {}):
            raise ValueError("Qwen3.6 独立引擎不支持 KV、YaRN 或视觉参数覆盖")
        native_context = (overrides or {}).get("--max-context")
        if native_context is not None and int(native_context) > 262144:
            raise ValueError("Qwen3.6 独立引擎的上下文上限为 262144")
    for flag, value in (overrides or {}).items():
        _set_arg(args, flag, value)
    config["args"] = args
    configs_dir.mkdir(parents=True, exist_ok=True)
    model_id = variant_id or profile.model_id
    if _safe_id(model_id) != model_id:
        raise ValueError("invalid model-tier result ID")
    phase_suffix = f"-{uniform_phase}" if uniform_phase in {"cache", "load"} else ""
    path = configs_dir / f"{model_id}-round-{round_number}{phase_suffix}.json"
    path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return ConfigSnapshot(
        model_id=model_id,
        model_name=profile.model_name,
        source_path=profile.config_path,
        source_hash=profile.config_hash,
        path=path,
        config=config,
        port=port,
    )


def profile_to_dict(profile: ModelProfile) -> dict[str, Any]:
    return {
        "model_id": profile.model_id,
        "model_name": profile.model_name,
        "config_path": str(profile.config_path),
        "config_hash": profile.config_hash,
        "port": profile.port,
        "exe": str(profile.config.get("exe", "")),
        "cwd": str(profile.config.get("cwd", "")),
    }

