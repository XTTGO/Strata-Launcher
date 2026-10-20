# Context Capacity Matrix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single benchmark context cap with selectable tiers and an opt-in per-tier full benchmark, including a measured near-capacity recall stage.

**Architecture:** Python owns tier selection, matrix execution, capacity judgement and reporting. PowerShell UI collects checkboxes and calls the same CLI contract. Each model-tier run gets a distinct snapshot/result ID; the no-tier default retains legacy behavior.

**Tech Stack:** Windows PowerShell 5.1 WinForms, Python stdlib/unittest, existing Strata launcher benchmark modules.

**Spec:** `launcher/docs/superpowers/specs/2026-10-12-context-capacity-matrix-design.md`

## Global Constraints

- Only `launcher/` is edited. Never write a source model config, official Strata setting, engine or server file.
- Tiers are exactly 32768, 65536, 131072, 262144, 393216, 524288 in ascending UI order.
- No tiers plus sweep off means the preexisting single-run path. Multiple tiers plus sweep off means only the smallest selected tier.
- Capacity passes only with two successful near-cap requests at each 10%, 50%, 90% depth; actual prompt tokens must reach at least 90% of configured tier.
- Above 262144, use current YaRN config rule. Preserve all old report rendering and CLI behavior for older manifests.
- Do not perform a 384K/512K live run without surfacing the time/resource cost. No auto-application to daily config.

## Review Focus

- Multiple selected tiers with sweep off must never silently run more than one; test UI confirmation and CLI resolution.
- A too-long legacy performance/needle/cache case under a lower cap is explicitly not-applicable, not counted as failure.
- Identical model at two tiers must not collide in snapshot, log, output, status or report aggregate.
- Near-cap recall correctness without enough actual tokens is not a capacity pass.
- Failure to stop a server blocks starting the next tier; startup resource failure leaves higher tiers unrun and labeled.

---

### Task 1: Tier parsing and UI selection

**Files:** Modify `launcher/benchmark/runner.py`, `launcher/Benchmark-Launcher.ps1`; create `launcher/tests/test_context_matrix.py`, `launcher/tests/Test-Strata-Benchmark-ContextMatrix.ps1`.

**Interfaces:** `resolve_context_tiers(selected: list[int] | None, sweep: bool, legacy_max_context: int | None = None) -> tuple[list[int | None], list[int]]` returns effective tiers and ignored selected tiers. CLI `--context-tiers` and `--sweep-context-tiers` add to, but do not break, `--max-context`.

- [x] Write Python tests for no tiers/default, 128K+512K with switch off/on, duplicate/unknown tiers, and legacy `--max-context`; run `python -m unittest launcher.tests.test_context_matrix`, expect missing function/errors.
- [x] Implement resolver and parser/estimate/run wiring, then rerun test, expect PASS.
- [x] Test the live Benchmark window/control labels and persisted selections in PowerShell; test smallest-tier behavior through the shared Python CLI resolver.
- [x] Replace dropdown with six checkboxes, add switch and capacity stage checkbox, preserve old saved `max_context`, confirmation effective list and CLI args; rerun PowerShell test, expect PASS.

### Task 2: Distinct model-tier execution and applicability

**Files:** Modify `launcher/benchmark/models.py`, `launcher/benchmark/runner.py`, `launcher/benchmark/report.py`; expand `launcher/tests/test_context_matrix.py`.

**Interfaces:** `snapshot_profile(..., variant_id: str | None = None) -> ConfigSnapshot`; matrix run descriptors pair source `ModelProfile` and cap. Record `source_model_id`, `context_tier` and unique `model_id` on every row. `eligible_context_cases(cap, performance_cases, needle_lengths) -> ...` provides runnable/skipped cases.

- [x] Add tests proving unique IDs/files for 128K+512K and unchanged legacy names; run, expect FAIL.
- [x] Implement model-tier descriptors/snapshots, round loop, request manifest model variants; run, expect PASS.
- [x] Add tests for too-long performance/needle/cache inputs and skip records; run, expect FAIL.
- [x] Implement per-tier applicability, status and error/cleanup handling; run, expect PASS.

### Task 3: Measured capacity probe

**Files:** Create `launcher/benchmark/capacity.py`, `launcher/tests/test_capacity.py`; modify `launcher/benchmark/runner.py`.

**Interfaces:** `run_capacity_probe(client, server, dirs, root, round_number, run_id, cap) -> list[dict]` emits six depth/repeat rows and status; `judge_capacity(rows, cap) -> dict` gives pass/fail/insufficient-evidence and actual-token range. No official tool edits.

- [x] Add tests with fake API replies for six hits/pass, one miss/fail, too-short actual prompt/insufficient evidence, request error and cancel; run, expect FAIL.
- [x] Implement near-cap filler with varied secret code, fresh-cache deterministic API calls, max-token reserve, bounded length correction, evidence and telemetry; run, expect PASS.
- [x] Wire the new `capacity` stage as first-round-only for each tier and preserve old stage defaults; run Python suite, expect PASS.

### Task 4: Per-tier report and backward compatibility

**Files:** Modify `launcher/benchmark/report.py`, `launcher/benchmark/share_image.py`; create/expand report tests in `launcher/tests`.

**Interfaces:** `summary.json` contains each model-tier as a distinct model entry and capacity judgement, plus per-source-model highest verified selected tier; old summary schema remains renderable.

- [x] Add synthetic two-tier report tests covering distinct metrics, maximum verified tier, actual prompt range, skipped/failed/untested states, and old manifest rendering; run, expect FAIL.
- [x] Implement HTML/Markdown/SVG and JSON summary matrix; run tests, expect PASS.

### Task 5: Packaging, regression and handoff

**Files:** Modify `launcher/README.txt` and package list only if new runtime files require it; update any affected tests.

- [x] Add/adjust share-package test for `capacity.py` and no local/private data; run, expect FAIL if omission exists.
- [x] Update README with checkbox/switch/capacity semantics and report caveats; generate a new versioned ZIP without overwriting prior packages.
- [x] Run all launcher Python and PowerShell tests, `Strata-Launcher.ps1 -CheckOnly`, package contents/privacy check; report exact outcomes. Run a live low-tier smoke test only if safe, while keeping high-tier workload user-triggered.

## Execution Notes

The launcher directory is currently untracked inside the official Strata repository on `main`; it contains user-owned files. Implement in place so the user's local launcher is actually updated. Do not create a Git commit, reset, or copy the whole launcher into a worktree without a separate user decision. Keep per-task red/green evidence in the task output and plan notes.
