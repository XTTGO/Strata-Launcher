from __future__ import annotations

import csv
import io
import json
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import psutil

from .models import ConfigSnapshot, RuntimePaths
from .storage import RunDirectories, is_cancelled, utc_now, write_status


CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_NO_WINDOW = 0x08000000


@dataclass
class TelemetrySampler:
    pid: int
    interval: float = 1.0
    stop_event: threading.Event = field(default_factory=threading.Event)
    samples: list[dict[str, Any]] = field(default_factory=list)
    thread: threading.Thread | None = None

    def start(self) -> None:
        self.thread = threading.Thread(target=self._run, daemon=True, name=f"strata-telemetry-{self.pid}")
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=3)

    def _run(self) -> None:
        while not self.stop_event.is_set():
            sample: dict[str, Any] = {"at": utc_now(), "rss_bytes": 0, "system_used_bytes": 0, "gpus": []}
            try:
                root = psutil.Process(self.pid)
                procs = [root] + root.children(recursive=True)
                sample["rss_bytes"] = sum(p.memory_info().rss for p in procs if p.is_running())
                sample["process_ids"] = [p.pid for p in procs if p.is_running()]
            except (psutil.Error, OSError):
                sample["process_ids"] = []
            try:
                sample["system_used_bytes"] = psutil.virtual_memory().used
            except (psutil.Error, OSError):
                pass
            sample["gpus"] = query_nvidia()
            self.samples.append(sample)
            self.stop_event.wait(self.interval)

    def summary(self, since_index: int = 0) -> dict[str, Any]:
        rows = self.samples[since_index:]
        return {
            "sample_count": len(rows),
            "rss_peak_bytes": max((int(r.get("rss_bytes", 0)) for r in rows), default=0),
            "system_used_peak_bytes": max((int(r.get("system_used_bytes", 0)) for r in rows), default=0),
            "gpu_memory_peak_mib": max(
                (int(g.get("memory_used_mib", 0)) for r in rows for g in r.get("gpus", [])), default=0
            ),
            "gpu_util_peak_percent": max(
                (int(g.get("util_percent", 0)) for r in rows for g in r.get("gpus", [])), default=0
            ),
        }


@dataclass
class OwnedServer:
    process: subprocess.Popen[Any]
    create_time: float
    python_path: Path
    snapshot: ConfigSnapshot
    log_path: Path
    log_handle: Any
    started_at: float
    load_seconds: float
    health: dict[str, Any]
    sampler: TelemetrySampler


@dataclass(frozen=True)
class StopResult:
    stopped: bool
    manual_cleanup_required: bool
    detail: str


def query_nvidia() -> list[dict[str, Any]]:
    try:
        cp = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=index,name,memory.total,memory.used,utilization.gpu,driver_version,pci.bus_id",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
            creationflags=CREATE_NO_WINDOW,
        )
        if cp.returncode != 0:
            return []
        result = []
        for row in csv.reader(io.StringIO(cp.stdout)):
            if len(row) < 7:
                continue
            result.append(
                {
                    "index": int(row[0].strip()),
                    "name": row[1].strip(),
                    "memory_total_mib": int(row[2].strip()),
                    "memory_used_mib": int(row[3].strip()),
                    "util_percent": int(row[4].strip()),
                    "driver_version": row[5].strip(),
                    "pci_bus_id": row[6].strip(),
                }
            )
        return result
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def port_state(port: int) -> dict[str, Any]:
    occupied = False
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=0.5):
            occupied = True
    except OSError:
        return {"port": int(port), "occupied": False, "kind": "free"}
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{int(port)}/health", timeout=2) as response:
            body = json.loads(response.read().decode("utf-8-sig"))
        return {"port": int(port), "occupied": occupied, "kind": "strata", "health": body}
    except (OSError, ValueError, json.JSONDecodeError, urllib.error.URLError):
        return {"port": int(port), "occupied": occupied, "kind": "unknown"}


def ensure_ports_free(ports: list[int]) -> None:
    busy = [port_state(p) for p in sorted(set(int(x) for x in ports)) if int(p) > 0]
    busy = [x for x in busy if x["occupied"]]
    if busy:
        details = "; ".join(f"{x['port']} ({x['kind']})" for x in busy)
        raise RuntimeError(f"以下端口已被占用，Benchmark 未启动任何模型：{details}")


def _health(port: int, timeout: float = 3) -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=timeout) as response:
            data = json.loads(response.read().decode("utf-8-sig"))
        return data if isinstance(data, dict) else None
    except (OSError, ValueError, json.JSONDecodeError, urllib.error.URLError):
        return None


def start_server(
    snapshot: ConfigSnapshot,
    paths: RuntimePaths,
    dirs: RunDirectories,
    round_number: int,
    ready_timeout: int = 1500,
) -> OwnedServer:
    log_path = dirs.logs / f"server-{snapshot.path.stem}.log"
    log_handle = log_path.open("w", encoding="utf-8", errors="replace")
    command = [
        str(paths.python),
        str(paths.server),
        "--engine",
        "strata",
        "--config",
        str(snapshot.path),
        "--port",
        str(snapshot.port),
    ]
    env = None
    config_env = snapshot.config.get("env")
    if isinstance(config_env, dict):
        import os

        env = os.environ.copy()
        env.update({str(k): str(v) for k, v in config_env.items()})
    started = time.time()
    process = subprocess.Popen(
        command,
        cwd=str(snapshot.config.get("cwd") or paths.root),
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        env=env,
        creationflags=CREATE_NEW_PROCESS_GROUP,
    )
    create_time = psutil.Process(process.pid).create_time()
    sampler = TelemetrySampler(process.pid)
    sampler.start()
    deadline = time.monotonic() + ready_timeout
    health = None
    try:
        while time.monotonic() < deadline:
            if is_cancelled(dirs):
                raise RuntimeError("用户请求停止 Benchmark")
            if process.poll() is not None:
                raise RuntimeError(f"Strata Server 启动退出，exit={process.returncode}，日志：{log_path}")
            health = _health(snapshot.port)
            if health and str(health.get("status", "ok")).lower() in {"ok", "ready"}:
                reported_model = str(health.get("model") or "")
                if reported_model and reported_model != snapshot.model_name:
                    raise RuntimeError(
                        f"端口 {snapshot.port} 返回了其他模型：{reported_model}，预期：{snapshot.model_name}"
                    )
                return OwnedServer(
                    process=process,
                    create_time=create_time,
                    python_path=paths.python.resolve(),
                    snapshot=snapshot,
                    log_path=log_path,
                    log_handle=log_handle,
                    started_at=started,
                    load_seconds=round(time.time() - started, 3),
                    health=health,
                    sampler=sampler,
                )
            write_status(dirs, state="loading", model_id=snapshot.model_id, round=round_number, message="正在加载模型")
            time.sleep(2)
        raise RuntimeError(f"等待 Strata Server 就绪超时（{ready_timeout} 秒），日志：{log_path}")
    except Exception:
        provisional = OwnedServer(
            process=process,
            create_time=create_time,
            python_path=paths.python.resolve(),
            snapshot=snapshot,
            log_path=log_path,
            log_handle=log_handle,
            started_at=started,
            load_seconds=round(time.time() - started, 3),
            health=health or {},
            sampler=sampler,
        )
        stop_server(provisional)
        raise


def _matches_owned_process(server: OwnedServer) -> tuple[bool, str]:
    try:
        proc = psutil.Process(server.process.pid)
        if abs(proc.create_time() - server.create_time) > 0.01:
            return False, "PID 已被其他进程复用"
        if Path(proc.exe()).resolve() != server.python_path:
            return False, f"Python 路径不匹配：{proc.exe()}"
        command = " ".join(proc.cmdline())
        if str(server.snapshot.path).lower() not in command.lower():
            return False, "进程命令行不包含本次配置快照"
        return True, "identity matched"
    except psutil.NoSuchProcess:
        return True, "process already exited"
    except (psutil.Error, OSError) as exc:
        return False, f"无法验证进程身份：{exc}"


def stop_server(server: OwnedServer) -> StopResult:
    server.sampler.stop()
    matched, detail = _matches_owned_process(server)
    if not matched:
        try:
            server.log_handle.flush()
            server.log_handle.close()
        except Exception:
            pass
        return StopResult(False, True, detail)
    try:
        root = psutil.Process(server.process.pid)
        children = root.children(recursive=True)
        for proc in children + [root]:
            try:
                proc.terminate()
            except psutil.Error:
                pass
        _, alive = psutil.wait_procs(children + [root], timeout=20)
        for proc in alive:
            try:
                proc.kill()
            except psutil.Error:
                pass
        psutil.wait_procs(alive, timeout=10)
        stopped = True
        detail = "owned process tree stopped"
    except psutil.NoSuchProcess:
        stopped = True
        detail = "process already exited"
    except psutil.Error as exc:
        stopped = False
        detail = str(exc)
    try:
        server.log_handle.flush()
        server.log_handle.close()
    except Exception:
        pass
    return StopResult(stopped, not stopped, detail)

