# Multi-GPU placement in the Windows launcher

The launcher lets a user assign one local Strata model to one or more NVIDIA GPUs. It follows the upstream Main / Helper / Off roles and keeps the engine's default automatic layer split. Existing model configurations retain their GPU placement when the user saves unrelated settings.

The GPU placement panel displays detected CUDA cards with stable identity, VRAM and supported status. It infers the current roles from `gpu_roles` or legacy `gpu`, and permits explicit editing. A change writes `gpu_roles`, `gpu`, `gpu_order`, and `layer_split` together. It rejects absent or changed cards, unsupported cards, zero or multiple Main roles, and a Helper too small for a split before any model config is saved. It preserves unrelated keys. It does not alter NVIDIA power caps.

The first release covers one model spanning NVIDIA cards. It does not manage multiple simultaneous model servers, manual layer boundaries or tuning flags. Validation includes offline PowerShell tests, the launcher test suite, package contents, and a real two-card inference check on the local RTX 3090 pair. The live result is recorded in `docs/superpowers/verification/2026-10-24-multi-gpu-live.md`.

Approaches considered: directly edit `gpu` only (insufficient for upstream role semantics); call setup on every selection (downloads and rewrites broader installation state); write the upstream config fields in the launcher's existing save transaction. The third approach fits the current configuration-based launcher and preserves the user's other model settings.
