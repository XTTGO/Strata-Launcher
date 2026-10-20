# Strata v0.1.44.1 launcher update and rollback

## Fixed versions and local recovery points

- Upstream source: `v0.1.44.1`, commit `296b59d2f73c8f04a805df29c2fa97655adace78`, on `codex/strata-v0.1.44.1-launcher-upgrade`.
- Previous source: commit `7695859aa13afb248bdb4d36f9b2e95707db079d`, still on `main`.
- Launcher before this work: local tag `baseline-v0.1.43-2026-10-14`, commit `5d0329e9d2a3b7fb3af7d3ee4a905cf173b7b578` in `launcher/.git`.
- Engine, model configurations and `%APPDATA%/Strata/settings.json`: `launcher/backups/upgrade-2026-10-14-v0.1.43/`. The local `manifest.json` has SHA-256 hashes. This directory stays outside the launcher Git history and sharing ZIP.
- The official update also saved the former engine in `engine/.previous`; its three top-level files matched the backup hashes after the update.

The model GGUFs and user data were not changed by `setup.py --update`. The update reported that its Python dependencies were already installed.

## Compatibility decisions

- Qwen3.6-35B-A3B uses the separate `arch=qwen35moe` path. The launcher preserves setup's `--mtp`, `--prefill`, and `--expert-vram`, shows their values, and limits its context picker to 256K. Flash-Next KV, YaRN, vision and calibration controls are inactive for that path. The shared `--native` flag alone does not identify Qwen3.6: installed Flash-Next IQ3_S also uses it. Its three published sizes need about 32/44/52 GB RAM; no Qwen3.6 GGUF was installed for a live test.
- The local GGUF import now detects family and size from the installed setup's model tables and passes both explicitly. For Flash-Next it checks all shards using setup's GGUF reader. For Qwen3.6 it checks the published file size; setup then verifies the published SHA-256. It no longer forces ModelScope as a source. The known local IQ3_S folder passed the preflight. The helper accepts published filenames in a single-model directory.
- The launcher benchmark continues to use Chat Completions for its tool cases. The v0.1.44.1 chat tool route remained compatible in a live named-tool smoke test. The new Responses route was checked separately with a real request; it is not represented as an agent benchmark score. Native-model context sweeps above 256K are rejected before a run. Temporary benchmark configs omit `--expert-profile-save` so a short run cannot overwrite the user's saved profile.
- Markdown reports now identify the workload and model snapshot, list safe launch parameters, GPU/driver and provenance, give per-stage coverage and per-record measurements, and link to complete JSONL and logs. Empty performance and concurrency tables are omitted. The official community format informed the hardware/settings/workload/limitations order; this launcher keeps its additional stage and memory detail. No single combined score was added.

## Roll back to the saved version

Stop Strata and close the launcher first. Confirm no `strata.exe` process is running. Run these commands in `D:\AI\Strata`:

```powershell
git switch main
git -C launcher switch main
.venv\Scripts\python.exe setup.py --rollback-engine
```

If the official engine rollback is unavailable, copy the backed-up `engine` contents from `launcher/backups/upgrade-2026-10-14-v0.1.43/engine/` after preserving the current engine separately. Restore the `strata-*.json` files from its `configs/` directory and, if needed, its `official-settings.json` to `%APPDATA%\Strata\settings.json`. Check the manifest hashes before copying. Rebuild the versioned ZIP under `launcher/dist/` from the selected launcher branch if a matching distribution ZIP is needed.

To return to this update, switch the upstream and launcher back to their `codex/...` branches and run `.venv\Scripts\python.exe setup.py --update`. A complete rollback was not executed during upgrade verification; the saved files and official `.previous` engine were hash-checked.
