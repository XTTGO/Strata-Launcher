# Strata Batch Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Windows batch benchmark tool to the existing Strata launcher that compares installed model profiles and produces traceable local JSON, Markdown, and HTML reports without modifying official Strata files or the original model configurations.

**Architecture:** Keep the WinForms launcher as a thin entry point. A separate Python controller under `launcher/benchmark/` discovers models, creates per-run configuration snapshots, owns every benchmark process, executes API and official-tool workloads, appends raw records, and renders reports. The controller communicates progress through a line-delimited status file so the PowerShell UI never performs long-running model or network work on its UI thread.

**Tech Stack:** Windows PowerShell 5.1 and WinForms; the existing `D:\AI\Strata\.venv\Scripts\python.exe`; Python standard library; existing `psutil`; Strata OpenAI-compatible HTTP API; official `tools/needle_bench.py` and `tools/serve_load.py`; local HTML/CSS/JavaScript with no downloaded dependencies.

**Spec:** `launcher/docs/2026-10-09-batch-benchmark-design.md`

## Global Constraints

- Treat `src/`, `include/`, `serve/`, `tools/`, `bench/`, `setup.py`, `START-HERE.bat`, `engine/strata.exe`, root `strata-*.json`, and `%APPDATA%\Strata\settings.json` as read-only.
- Bind benchmark servers only to `127.0.0.1` and never persist an API key.
- Use configuration copies inside the report directory; never rewrite the original model JSON.
- Keep all new code, documentation, runtime state, and reports under `launcher/`.
- Download no models, packages, programs, or updates.
- Stop only processes started by the current benchmark run and revalidated by PID, executable path, parent chain, and port identity.
- Append every completed request to `raw-results.jsonl` immediately.
- Preserve successful records when a request, model, stage, or whole run fails or is cancelled.
- Do not reduce separate speed, recall, Agent, concurrency, memory, and stability results to one composite score.
- Do not add or run automated tests unless the user separately requests testing or verification; implementation review uses code inspection and explicit runtime validation only when authorized.
- Keep the custom launcher untracked unless the user separately requests a Git commit.

## Review Focus

- A root `strata-*.json` disappears or becomes invalid between discovery and launch: mark that model failed before starting a process and continue with the remaining models (Task 1 and Task 3).
- Port 8080 or the dedicated benchmark port is occupied by an unrelated process: refuse to begin and do not terminate it (Task 2 and Task 3).
- The UI or controller is closed while a model is loading: retain the report, validate ownership, and stop only the recorded process tree (Task 2 and Task 7).
- A stage returns malformed API JSON, partial JSONL, or nonzero official-tool output: record the failure and generate a readable partial report (Task 4, Task 5, and Task 6).
- Paths contain spaces, Chinese characters, or a moved Strata root: pass argument arrays and derive paths from the launcher location instead of assembling shell strings (Task 1, Task 2, and Task 7).

---

## File Map

### Create

- `launcher/benchmark/__init__.py` — package marker and format version.
- `launcher/benchmark/models.py` — discover and validate model profiles; create immutable configuration snapshots.
- `launcher/benchmark/processes.py` — port checks, server startup, health wait, telemetry sampling, PID ownership, and safe shutdown.
- `launcher/benchmark/workloads.py` — fixed prompt construction, API requests, warm-up, performance, cache, and stability workloads.
- `launcher/benchmark/agent_eval.py` — load Agent cases and apply deterministic scorers.
- `launcher/benchmark/official_tools.py` — invoke and normalize `needle_bench.py` and `serve_load.py` results.
- `launcher/benchmark/storage.py` — create report directories and atomically maintain manifest, status, and JSONL data.
- `launcher/benchmark/report.py` — aggregate raw records and generate JSON, Markdown, and standalone HTML.
- `launcher/benchmark/runner.py` — command-line entry point and state-machine orchestration.
- `launcher/benchmark/agent_cases.json` — versioned deterministic Agent workload definitions.
- `launcher/Benchmark-Launcher.ps1` — independent WinForms configuration and progress window.
- `launcher/data/benchmark-settings.json` — generated UI preference file; absent on first run.

### Modify

- `launcher/Strata-Launcher.ps1` — add one “批量 Benchmark” button that opens `Benchmark-Launcher.ps1`.
- `launcher/README.txt` — document prerequisites, runtime behavior, report locations, and safe cancellation.

### Generated at runtime

- `launcher/reports/<timestamp>_<preset>/` — manifest, status, raw data, snapshots, logs, answers, and reports.

## Stable Interfaces

The implementation must keep these boundaries so components can evolve independently:

- `models.discover_profiles(root: Path) -> list[ModelProfile]`
- `models.snapshot_profile(profile: ModelProfile, run_dirs: RunDirectories, port: int, overrides: dict[str, str | None]) -> ConfigSnapshot`
- `processes.ensure_ports_free(ports: list[int]) -> None`
- `processes.start_server(snapshot: ConfigSnapshot, paths: RuntimePaths, run_dirs: RunDirectories) -> OwnedServer`
- `processes.stop_server(server: OwnedServer) -> StopResult`
- `workloads.run_performance(client: StrataClient, case: PerformanceCase, sampler: TelemetrySampler) -> RawRecord`
- `workloads.run_cache_sequence(client: StrataClient, case: CacheCase, sampler: TelemetrySampler) -> list[RawRecord]`
- `agent_eval.run_agent_case(client: StrataClient, case: AgentCase) -> AgentRecord`
- `official_tools.run_needle(server: OwnedServer, case: NeedleCase, run_dirs: RunDirectories) -> list[RawRecord]`
- `official_tools.run_load(server: OwnedServer, case: LoadCase, run_dirs: RunDirectories) -> list[RawRecord]`
- `storage.append_record(run_dirs: RunDirectories, record: dict) -> None`
- `report.build_summary(run_dir: Path) -> dict`
- `report.render_reports(run_dir: Path, summary: dict) -> ReportPaths`

All serialized records include `schema_version`, `run_id`, `model_id`, `config_snapshot`, `round`, `stage`, `case_id`, `status`, UTC timestamps, actual token counts, timing fields, and an optional structured `error`.

---

### Task 1: Model Discovery, Run Storage, and Immutable Snapshots

**Files:**

- Create: `launcher/benchmark/__init__.py`
- Create: `launcher/benchmark/models.py`
- Create: `launcher/benchmark/storage.py`

**Consumes:** Launcher root derived from each script's own location; the existing `strata-*.json` schema.

**Produces:** `ModelProfile`, `RuntimePaths`, `RunDirectories`, `ConfigSnapshot`, run manifest/status helpers, and append-only record storage used by all later tasks.

- [ ] Define dataclasses for profile identity, runtime paths, run directories, and snapshot metadata. `model_id` must be a filesystem-safe stable value derived from `model_name` plus the configuration filename.
- [ ] Implement `discover_profiles()` with the launcher's existing validity rules: filename matches `strata-*.json`, excludes `*.shared-settings.json`, and requires nonempty `exe`, `args`, and `model_name`.
- [ ] Resolve every relative path against the Strata root and retain the original JSON bytes and SHA-256 in `ModelProfile`.
- [ ] Implement `create_run_directories()` for `configs`, `prompts`, `answers`, and `logs`, and write `run-manifest.json` with `schema_version`, preset, requested stages, selected profiles, and state `preparing`.
- [ ] Implement atomic JSON replacement for manifest/status and line-flushed UTF-8 JSONL append for records.
- [ ] Implement `snapshot_profile()` by cloning JSON in memory, overriding the test port and explicitly requested engine flags, and writing only under the run's `configs/` directory.
- [ ] Add prelaunch revalidation that compares the root configuration's current SHA-256 with discovery time and rejects only the changed model.
- [ ] Inspect the implementation against Review Focus items for invalid profiles and Unicode/space paths; do not run validation commands until authorized.

### Task 2: Owned Server Lifecycle and Telemetry

**Files:**

- Create: `launcher/benchmark/processes.py`

**Consumes:** `RuntimePaths`, `ConfigSnapshot`, `RunDirectories`, and status writers from Task 1.

**Produces:** `OwnedServer`, `TelemetrySampler`, `StopResult`, and server health/identity checks used by the runner and workloads.

- [ ] Implement loopback-only port probing that distinguishes free, responding Strata, and unknown listeners; any listener blocks startup.
- [ ] Start the existing `.venv` Python with `serve/server.py --engine strata --config <snapshot> --port <port>` by argument array, with stdout/stderr redirected to a timestamped model/round log.
- [ ] Record controller PID, server PID, command arguments, executable paths, creation times, test port, config hash, and model identity before waiting for readiness.
- [ ] Poll process exit plus `/health` until success or configured timeout; verify returned model identity before declaring readiness.
- [ ] Sample once per second: server process-tree RSS, system used memory, per-GPU memory used/utilization from `nvidia-smi`, and observed process IDs.
- [ ] Implement safe shutdown by rechecking process creation time, executable path, parent chain, command/config identity, and port health before terminating the owned tree.
- [ ] On ambiguous identity, leave the process untouched, mark `manual_cleanup_required`, and write diagnostics into the manifest and report.
- [ ] Install controller signal/console handlers that set a cancellation flag; cleanup occurs through the same ownership-checked stop path.
- [ ] Inspect the implementation against Review Focus items for occupied ports and cancellation during model loading; do not run validation commands until authorized.

### Task 3: Orchestrator, Presets, and Alternating Model Order

**Files:**

- Create: `launcher/benchmark/runner.py`

**Consumes:** Profile/storage interfaces from Task 1 and process interfaces from Task 2.

**Produces:** CLI commands `list-models`, `estimate`, `run`, `cancel`, `status`, and `render`; the canonical stage state machine.

- [ ] Define `standard` and `full` presets exactly as specified, with a versioned resolved plan written into the manifest before model startup.
- [ ] Accept explicit model configuration paths, preset, selected stages, repetitions, benchmark port, and report root as argument-array CLI options.
- [ ] Reject fewer than one valid model, duplicate models, invalid repetitions, non-loopback URLs, missing `.venv` Python, missing `serve/server.py`, missing official tools, and unwritable report roots before starting a model.
- [ ] Probe the dedicated benchmark port plus every unique daily-service port declared by the selected source profiles; if any responds as Strata or is occupied by an unknown listener, stop before creating a model process and report the exact port and observed identity.
- [ ] Capture `hardware.json` before model startup: Windows version, CPU, installed RAM, NVIDIA GPU name/VRAM/driver, current PCIe data reported by `nvidia-smi`, Strata Git revision when available, engine executable metadata, and unavailable fields explicitly marked `null`.
- [ ] Implement alternating round order: original order on even rounds and reversed order on odd rounds.
- [ ] For every model/round, revalidate source config, create a round snapshot, start, warm up, execute resolved stages, stop, and persist phase transitions.
- [ ] Treat a model startup failure as a model/round failure, preserve its log, stop owned remnants, and continue other models.
- [ ] Define cancellation as an atomically created `<run_dir>/cancel.request` sentinel containing request time and controller PID. The runner checks it before and after every request and during readiness polling, then enters ownership-checked cleanup, marks the run `cancelled`, and renders a partial report.
- [ ] Restore no service automatically and never rewrite `launcher/data/selected.txt`.
- [ ] Inspect state transitions for all preflight, failure, and cancellation paths; do not run validation commands until authorized.

### Task 4: Performance, Cache, and Stability Workloads

**Files:**

- Create: `launcher/benchmark/workloads.py`

**Consumes:** `OwnedServer`, telemetry sampling, cancellation state, and `append_record()`.

**Produces:** `StrataClient`, prompt artifacts, normalized performance/cache/stability records.

- [ ] Implement a standard-library HTTP client for `/health`, `/metrics`, and `/v1/chat/completions`, with explicit timeouts and structured HTTP/JSON errors.
- [ ] Build deterministic prompts from fixed UTF-8 local Strata docs/source, trim by server-reported token counts where practical, and store the final prompt artifact and SHA-256 for 4K, 32K, 128K, and 256K targets.
- [ ] Read the started server's reported maximum context before a case; emit `skipped/context_limit` when the target prompt plus output allowance cannot fit instead of sending an oversized request.
- [ ] Add unique nonce text to uncached performance requests while preserving the shared measured body across models.
- [ ] Implement non-counted warm-up and mark every warm-up record `excluded_from_summary=true`.
- [ ] Implement performance requests with thinking off, `temperature=0`, `max_tokens=256`, `cache_prompt=false`, and normalized server timing fields.
- [ ] Derive TTFT from a streamed probe where required and never calculate decode tok/s by dividing completion tokens by total wall time.
- [ ] Implement the 32K three-turn cache sequence, capturing prompt tokens, reused tokens, newly processed tokens, TTFT, server timings, and telemetry for each turn.
- [ ] Implement the full-preset stability sequence with fixed request count, per-request status, throughput drift, high-water memory, and server liveness.
- [ ] Append each result before moving to the next request and store raw responses under `answers/<model>/<round>/`.
- [ ] On malformed API JSON or partial streaming data, preserve response excerpts without secrets and emit a failure record rather than raising past the stage boundary.

### Task 5: Deterministic Agent Evaluation

**Files:**

- Create: `launcher/benchmark/agent_cases.json`
- Create: `launcher/benchmark/agent_eval.py`

**Consumes:** `StrataClient`, raw-record storage, and answer storage.

**Produces:** Versioned Agent cases and `AgentRecord` results with assertion-level evidence.

- [ ] Define standard cases for JSON schema, tool-call arguments, multiple constraints, multi-turn state, failed-tool correction, local code repair, evidence retrieval, and thinking-off behavior.
- [ ] Give every case a stable ID, case version, API parameters, expected assertions, timeout, and standard/full membership.
- [ ] Implement scorer types: JSON parse/schema subset, exact value, regex, required/forbidden strings, ordered steps, tool name/argument match, and local command result for the isolated code fixture.
- [ ] Create code fixtures only inside the run report directory and restrict validation commands to that fixture directory.
- [ ] Store the original model response and an assertion list containing expected value, observed value, and pass/fail; do not store hidden chain-of-thought.
- [ ] Run main Agent cases with `reasoning_effort=medium`, `temperature=0`, and a fixed seed; run thinking-off compliance separately with `reasoning_effort=none` and `enable_thinking=false`.
- [ ] Report mechanical pass rates by category and keep unscored qualitative text outside the pass-rate denominator.

### Task 6: Official Tool Adapters and Unified Reports

**Files:**

- Create: `launcher/benchmark/official_tools.py`
- Create: `launcher/benchmark/report.py`

**Consumes:** Owned server identity, run directories, records from Tasks 1–5, and read-only official scripts.

**Produces:** Normalized needle/load records, `summary.json`, `report.md`, and standalone `report.html`.

- [ ] Invoke `tools/needle_bench.py` through the existing `.venv` Python with explicit loopback URL, lengths, depths, timeout, and an output path inside the run directory.
- [ ] Normalize successes, misses, errors, and context-based skips into the shared raw-record schema while retaining the official JSON and console log.
- [ ] Invoke `tools/serve_load.py` with explicit clients, rounds, max tokens, fixed nonce, and JSON output inside the run directory.
- [ ] Normalize total throughput, per-request throughput, TTFT P50/P95, latency P50/P95, and errors while retaining official output.
- [ ] Make nonzero official-tool exits stage failures with preserved output; continue later stages when the owned server remains healthy.
- [ ] Aggregate only non-warm-up successful records and compute sample count, median, minimum, maximum; preserve failures and skips separately.
- [ ] Produce per-model sections for startup, prompt/decode speed, TTFT, cache, Agent assertions, needle recall, concurrency, stability, and memory.
- [ ] Include config hashes, actual source config names, Strata/engine versions, hardware facts, common workload parameters, and limitations.
- [ ] Generate Markdown and a standalone HTML file with embedded CSS/JavaScript and no remote assets; link every summary cell to its contributing raw record IDs.
- [ ] Render useful partial reports from truncated JSONL, malformed individual records, cancelled runs, or all-failed stages.

### Task 7: Benchmark WinForms UI and Main Launcher Integration

**Files:**

- Create: `launcher/Benchmark-Launcher.ps1`
- Modify: `launcher/Strata-Launcher.ps1` near the existing official-tools button layout and click handlers.
- Modify: `launcher/README.txt`

**Consumes:** Runner CLI and status/manifest formats from Tasks 1–6.

**Produces:** User-facing model selection, preset/stage controls, progress display, safe stop, and report-opening flow.

- [ ] Build an independent resizable WinForms window that calls `runner.py list-models --json` and presents checked models, model/config paths, preset, stages, repetitions, and report location.
- [ ] Default to all currently valid models, the standard preset, three repetitions, and the design's standard stages.
- [ ] Save UI-only preferences atomically to `launcher/data/benchmark-settings.json`; never copy engine settings into it.
- [ ] Before launch, show the resolved model list and high-cost stages; start the controller as a hidden process with argument arrays and record its PID/run directory.
- [ ] Poll `status.json` with a WinForms timer and update progress without blocking the UI thread or repainting on mouse movement.
- [ ] Implement “安全停止” by signaling the recorded controller through its cancel command/state, then let the controller perform owned-process cleanup.
- [ ] Implement “打开报告目录”和“打开报告”; enable the HTML button only when `report.html` exists.
- [ ] On window close during an active run, offer to leave the benchmark running or request safe stop; never call broad `taskkill` by process name.
- [ ] Add one `批量 Benchmark` button to the main launcher's official-tools group and open `Benchmark-Launcher.ps1` with the current PowerShell executable and launcher-relative path.
- [ ] Update `README.txt` with prerequisites, presets, output paths, safe-stop behavior, partial reports, and the statement that official files and original model JSON remain unchanged.
- [ ] Inspect path quoting, PowerShell's case-insensitive variables, timer disposal, and existing main-launcher handlers; do not run validation commands until authorized.

### Task 8: Integration Review and User-Authorized Runtime Validation

**Files:**

- Review: all files above
- Generated only when authorized: one disposable report under `launcher/reports/`

**Consumes:** Complete implementation.

**Produces:** A review record describing inspected invariants and, if separately authorized, measured runtime validation results.

- [ ] Compare the implementation against every design-spec section and acceptance criterion.
- [ ] Inspect `git diff -- launcher` plus `git status --short` and confirm no official tracked file changed.
- [ ] Hash all root `strata-*.json` and `%APPDATA%\Strata\settings.json` before any authorized live run; compare afterward.
- [ ] If the user authorizes structural verification, run PowerShell AST parsing and Python compilation/import checks without starting a model.
- [ ] If the user authorizes live verification, use one selected model, a disposable short preset, a dedicated free port, one repetition, and reduced prompt lengths; verify startup, result append, cancellation/cleanup, and partial/final report rendering.
- [ ] If the user authorizes a full acceptance run, execute the standard three-model preset only after confirming no daily Strata server is active.
- [ ] Record validation boundaries explicitly: structural checks do not prove GPU execution; a short live run does not prove 128K/256K behavior; only the completed selected preset supports its report conclusions.

---

## Implementation Order

1. Tasks 1–2 establish immutable data and safe ownership.
2. Task 3 supplies a runnable controller with no workloads beyond warm-up.
3. Tasks 4–5 add native benchmark and Agent records.
4. Task 6 integrates official tools and turns raw data into reports.
5. Task 7 exposes the completed controller in the launcher.
6. Task 8 performs review and any separately authorized validation.

The UI must not be implemented before process ownership and append-only storage are stable, because cancellation and partial-report behavior depend on those interfaces.
