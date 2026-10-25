# DeepSeek compatibility and official presets implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the launcher write only supported DeepSeek settings and use family-specific official sampling defaults while preserving Qwen behavior.

**Architecture:** Keep the existing source-install `serve/server.py --engine strata --config ...` launch path. Put engine-family rules and argument normalization in `Strata-Launcher-Settings.ps1`; keep WinForms as an editor of those rules. The official v0.2.5 tag and its two engines are the reference; runtime changes are separate from source-only verification.

**Tech Stack:** Windows PowerShell 5.1, WinForms, Python unittest, official Strata v0.2.5 source.

**Spec:** `docs/strata-v0.2.5-presets-and-launcher-gap.md`; official `docs/DEEPSEEK41.md`, `serve/server.py`, `src/dsv41/ds4_main.cpp` at tag v0.2.5.

## Global constraints

- Preserve the existing Strata run configs and the runtime copy `D:\AI\Strata\launcher`; edit development source on `codex/deepseek-compat-presets`.
- DeepSeek engine 0.1.49.2 rejects `--experts`; 0.1.50+ accepts `auto`, `5`, and `6`. `--dspark none` skips drafter loading; `off` still loads it.
- DeepSeek model-card sampling: `temperature=1.0`, `top_p=1.0`; no model-card `top_k` or penalty. Qwen3.8 and Qwen3.6 have distinct presence-penalty defaults.
- Do not silently replace unknown official engine flags or unrelated run-config fields. Flag sanitization must be explicit and testable.
- `reasoning_budget_tokens=0` is an explicit unlimited budget; absent means use the server default.

## Review focus

- A DeepSeek config without `--max-context` must open at 8192, not the Qwen fallback.
- Saving a DeepSeek config must preserve its pack, EOS, GPU selection and independently supported args while removing Qwen-only flags and ineffective sampling penalties.
- An old DeepSeek engine must never receive `--experts`; an engine 0.1.50+ may receive 5/6 only by explicit user choice.
- Switching to official model-card defaults must clear old model and shared overrides, including `top_k=20` and `top_p=0.95` for DeepSeek.
- A Qwen config must retain Qwen-specific controls, aliases, and its own model-card defaults after the DeepSeek changes.

---

### Task 1: DeepSeek argument and version compatibility

**Files:** `Strata-Launcher-Settings.ps1`, `Strata-Launcher.ps1`, `tests/Test-Strata-Launcher-DeepSeekArgs.ps1`, new focused tests if needed.

- [x] Add failing tests for `--dspark none`, SSD `auto` omission, `--experts` version gate, preserved `--tp` values, and unsupported Qwen flags.
- [x] Run the focused tests and record expected failures.
- [x] Implement the smallest family-specific settings and UI changes.
- [x] Run focused tests, then the existing launcher suite.

### Task 2: Official per-family generation presets

**Files:** `Strata-Launcher-Settings.ps1`, `Strata-Launcher.ps1`, `tests/Test-Strata-Launcher-UsagePresets.ps1`, `tests/Test-Strata-Launcher-Sampling.ps1`.

- [x] Add failing tests for Qwen3.8, Qwen3.6, and DeepSeek model-card values and for an explicit official-default reset.
- [x] Run the focused tests and record expected failures.
- [x] Implement family-aware presets, hide unsupported DeepSeek penalty controls, and preserve absent fields when using official defaults.
- [x] Run focused tests and verify the loaded UI and saved JSON with a temporary config copy.

### Task 3: Startup path and source-install integration audit

**Files:** `Strata-Launcher.ps1`, `Strata-Launcher-Lan.ps1` only if a reproducible issue is found; existing startup tests and documentation.

- [x] Check the exact `server.py --engine strata` contract, executable selection, `user_args` merge, model file detection, GPU mapping, and port/key handling against v0.2.5.
- [x] Add a failing regression test for every found startup bug; fix only demonstrated issues.
- [x] Run `-CheckOnly`, focused PowerShell tests, and `Run-Launcher-Tests.py` against the local Strata checkout.
- [x] Record which checks are source-only and which, if any, use a real model.

Implementation evidence and remaining live-model boundary: `docs/deepseek-compat-worklog-2026-10-25.md`.
