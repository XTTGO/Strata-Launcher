# Two RTX 3090 live verification (2026-10-24)

Branch: `codex/multi-gpu-launcher`. Source version: `0.1.7-dev.1`. Strata engine: `0.1.48`, CUDA 13.0, build commit `6f8800aefe27`. Model: `qwen3.8-flash-next-iq3_s`.

The opt-in check is `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Strata-Launcher-MultiGpu-Smoke.ps1`. It creates a config copy under `tests/.tmp`, uses only `127.0.0.1:18080`, loads the model, sends a text-only request, and stops the server. It does not rewrite the installed model config. The observed raw report and server logs are in `tests/.tmp/multi-gpu-smoke-20261024-105446/` on this machine; the folder is intentionally ignored by Git.

| Check | Observed |
| --- | --- |
| Placement | GPU 0 Helper, GPU 1 Main, `gpu=[0,1]`, `layer_split=auto` |
| Engine layers | 0-23 on CUDA0; 24-47 on CUDA1; one hand-off per window |
| GPU 0 VRAM | 1,747 MiB before; 21,026 MiB loaded |
| GPU 1 VRAM | 0 MiB before; 20,307 MiB loaded |
| API | `/health` loaded=true; `/v1/chat/completions` replied `OK`, finish_reason=`stop` |
| Duration | 32.2 seconds to reply in the successful run |
| Cleanup | No Strata or vision process remained; GPU 1 returned to 0 MiB and GPU 0 to its prior desktop load |

After the live run: `Run-Launcher-Tests.py --strata-root D:\AI\Strata` passed 134 tests. The GPU placement, WinForms UI, and share-package PowerShell checks all passed. The original `D:\AI\Strata\strata-iq3_s.json` still has `gpu=0`, no `gpu_roles`, and port 8080. The runtime launcher copy was not synchronized. This check establishes one model split across two NVIDIA cards on this PC; it does not establish simultaneous separate model servers, manual split tuning, or comparative performance.
