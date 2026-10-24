# Strata Monitor overlay verification (2026-10-24)

Branch: `codex/multi-gpu-launcher`. Source version: `0.1.7-dev.2`. The runtime launcher copy was not synchronized.

- The launcher UI smoke check found the new 悬浮监控 entry. A click-through UI check clicked that button in the visible launcher and found a visible, independent overlay. A separate Windows PowerShell 5 WinForms smoke check found the overlay's metric sections and opacity control, then toggled the mouse click-through window style.
- The helper's authenticated loopback fake-server test read `/v1/telemetry`, projected selected-device readings and completed-request summaries, and excluded injected prompt, answer and key fields. The launcher Python suite passed 138 tests. The share-package test found both new monitor files in the ZIP snapshot.
- During the isolated two-RTX-3090 model run on `127.0.0.1:18080`, `Strata-Monitor-Snapshot.py` read a live `server-v1` snapshot with `loaded=true`, `active=1`, `queued=0`, GPU 0 memory `22406131712/25769803776` bytes, GPU 1 memory `21555232768/25769803776` bytes, and host RAM. The speed field was unavailable at that polling instant. The separate inference smoke check finished with a short `OK` reply and stopped its server. The source model config was not rewritten.

The live read checked the data path while the model ran; the complete overlay UI was not observed through a live model response. The tray recovery action and opacity slider are implemented but have not had a physical mouse acceptance check. The overlay remains a local development feature until the runtime copy is synchronized and reviewed.
