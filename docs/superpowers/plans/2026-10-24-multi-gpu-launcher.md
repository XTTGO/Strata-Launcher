# Multi-GPU Launcher Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox syntax for tracking.

**Goal:** Let the Windows launcher explicitly assign Main, Helper and Off roles for one Strata model across NVIDIA GPUs.

**Architecture:** A focused PowerShell module owns inventory parsing, config projection and validation. The WinForms launcher reads that module for the placement panel and applies placement only when the user edits it. Packaging includes the module.

**Tech Stack:** Windows PowerShell 5, WinForms, `nvidia-smi`, existing PowerShell tests.

**Spec:** `docs/superpowers/specs/2026-10-24-multi-gpu-launcher.md`

## Global Constraints

- Keep current model settings and GPU placement untouched on unrelated saves.
- Write the official `gpu_roles`, `gpu`, `gpu_order`, `layer_split` fields consistently.
- Validate GPU identity again immediately before saving.
- Do not modify the installed runtime copy or start an inference job during offline development.

## Review Focus

- Number reused by a different physical GPU: reject rather than silently select the wrong card.
- CUDA engine missing or incompatible: disable placement editing and preserve existing config.
- Legacy `gpu` list: display its last card as Main without rewriting until edited.
- Zero or multiple Main roles: reject before writing.
- Single GPU selection after a split: remove stale split settings.

---

### Task 1: GPU placement module

**Files:** Create `Strata-Launcher-GpuPlacement.ps1`; test `tests/Test-Strata-Launcher-GpuPlacement.ps1`.

- [x] Add failing tests for inventory parsing, legacy role projection, valid single/split writes and invalid placements.
- [x] Run the targeted test and confirm it fails for missing functionality.
- [x] Implement inventory, projection, validation and config update functions.
- [x] Run the targeted test and confirm it passes.

### Task 2: WinForms integration and packaging

**Files:** Modify `Strata-Launcher.ps1`, `Build-Launcher-Package.ps1`, `tests/Test-Strata-Launcher-SharePackage.ps1`, `README.txt`.

- [x] Add a user-visible GPU placement panel with explicit edit mode and current role display.
- [x] Apply changes through the module during the existing save transaction.
- [x] Add the module to the package and test its presence.
- [x] Run the Python launcher suite, focused PowerShell checks, UI smoke check, and package check.

### Task 3: Review and report

- [x] Inspect the branch diff for unintended runtime or data changes.
- [x] Confirm branch, tests, and remaining real-GPU validation boundary.
