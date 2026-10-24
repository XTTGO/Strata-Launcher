"""Opt-in live check of the launcher's two-card placement on a local Strata install."""

import json
import re
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


def gpu_memory() -> dict[int, int]:
    output = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=index,memory.used", "--format=csv,noheader,nounits"],
        text=True,
        timeout=15,
    )
    return {int(index.strip()): int(mib.strip()) for index, mib in
            (line.split(",", 1) for line in output.splitlines())}


def get_json(url: str, timeout: float = 3) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.load(response)


def main() -> int:
    root, snapshot, port, startup_timeout = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    out = snapshot.parent
    config = json.loads(snapshot.read_text(encoding="utf-8"))
    server = root / "serve" / "server.py"
    if not server.is_file():
        raise FileNotFoundError(server)
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", port)) == 0:
            raise RuntimeError(f"Port {port} is already in use")

    before = gpu_memory()
    started = time.monotonic()
    stdout = (out / "server.stdout.log").open("w", encoding="utf-8")
    stderr = (out / "server.stderr.log").open("w", encoding="utf-8")
    process = None
    result = None
    try:
        process = subprocess.Popen(
            [sys.executable, str(server), "--engine", "strata", "--config", str(snapshot),
             "--host", "127.0.0.1", "--port", str(port)],
            cwd=root, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        deadline = started + startup_timeout
        health = None
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"Server exited before ready: {process.returncode}")
            try:
                health = get_json(f"http://127.0.0.1:{port}/health")
                if health.get("loaded"):
                    break
            except (OSError, ValueError):
                pass
            time.sleep(3)
        if not health or not health.get("loaded"):
            raise TimeoutError(f"Server was not ready after {startup_timeout} seconds")

        loaded = gpu_memory()
        body = json.dumps({
            "model": config["model_name"],
            "messages": [{"role": "user", "content": "Reply only OK."}],
            "max_tokens": 32,
            "reasoning_effort": "none",
            "stream": False,
        }).encode("utf-8")
        request = urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            answer = json.load(response)
        content = answer.get("choices", [{}])[0].get("message", {}).get("content")
        engine_log = Path(config["log"]).read_text(encoding="utf-8")
        split = next((line for line in engine_log.splitlines()
                      if re.search(r"layer split: layers .*CUDA0.*CUDA1", line)), None)
        result = {
            "config": str(snapshot), "model": config["model_name"],
            "gpu": config["gpu"], "gpu_roles": config["gpu_roles"],
            "layer_split": config["layer_split"], "engine_split": split,
            "gpu0_memory_before_mib": before[0], "gpu0_memory_loaded_mib": loaded[0],
            "gpu1_memory_before_mib": before[1], "gpu1_memory_loaded_mib": loaded[1],
            "health": health, "reply": content,
            "finish_reason": answer["choices"][0]["finish_reason"],
            "usage": answer.get("usage"),
            "elapsed_seconds": round(time.monotonic() - started, 1),
        }
        (out / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        if loaded[0] <= before[0] + 512 or loaded[1] <= before[1] + 512:
            raise AssertionError("Both GPUs did not gain substantial model memory")
        if not split:
            raise AssertionError("Engine did not report a CUDA0/CUDA1 layer split")
        if not isinstance(content, str) or not content.strip():
            raise AssertionError("Chat completion has no answer text")
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        stdout.close()
        stderr.close()

    print(f"PASS: two GPUs loaded and short completion answered; {out / 'result.json'}")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
