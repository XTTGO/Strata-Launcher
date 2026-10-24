import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen


SOURCE = pathlib.Path(__file__).resolve().parents[1] / "Strata-Monitor-Snapshot.py"
SPEC = importlib.util.spec_from_file_location("strata_monitor_snapshot", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MonitorSnapshotTests(unittest.TestCase):
    def test_selected_cards_and_redacted_requests(self):
        snapshot = {
            "source": "server-v1", "instance": {"id": "new-instance"},
            "model": {"id": "model-a", "loaded": True},
            "work": {"active": 1, "queued": 0},
            "rates": {"answer_tok_s": 42.5, "prefill_tok_s": 100.0},
            "topology": {"selected_devices": [1, 0]},
            "devices": [
                {"index": 0, "name": "GPU A", "util": 70, "mem_used": 10, "mem_total": 20},
                {"index": 1, "name": "GPU B", "util": 80, "mem_used": 12, "mem_total": 24},
                {"index": 2, "name": "unselected", "util": 99},
            ],
            "ram": {"used": 30, "total": 64},
            "recent": [{"time": 100, "finish": "stop", "prompt_tokens": 4,
                        "output_tokens": 8, "duration_s": 2, "prompt": "private text",
                        "answer": "private answer", "api_key": "private key"}],
        }
        output = MODULE.view_model(snapshot)
        self.assertEqual([r["index"] for r in output["devices"]], [1, 0])
        self.assertEqual(output["answer_tok_s"], 42.5)
        self.assertEqual(output["recent"][0]["output_tokens"], 8)
        serialized = json.dumps(output)
        for secret in ("private text", "private answer", "private key"):
            self.assertNotIn(secret, serialized)

    def test_missing_fields_remain_unavailable(self):
        output = MODULE.view_model({"model": {}, "rates": {}, "quality": {"telemetry": "unavailable"}})
        self.assertIsNone(output["answer_tok_s"])
        self.assertFalse(output["telemetry_available"])
        self.assertEqual(output["devices"], [])

    def test_duplicate_selected_sensor_is_not_claimed(self):
        output = MODULE.view_model({
            "topology": {"selected_devices": [0]},
            "devices": [{"index": 0, "util": 10}, {"index": 0, "util": 99}],
        })
        self.assertEqual(output["devices"][0]["index"], 0)
        self.assertIsNone(output["devices"][0]["util"])

    def test_read_only_authenticated_telemetry_poll(self):
        strata_root = SOURCE.parent.parent / "Strata"
        if not (strata_root / "strata_cli" / "client.py").is_file():
            self.skipTest("sibling Strata source is required for the packaged launcher workflow")

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/v1/telemetry" or self.headers.get("Authorization") != "Bearer fixture-key":
                    self.send_error(401)
                    return
                body = json.dumps({
                    "schema_version": 1, "source": "server-v1",
                    "model": {"id": "fixture-model", "loaded": True},
                    "rates": {"answer_tok_s": 37.5},
                    "topology": {"selected_devices": [0]},
                    "devices": [{"index": 0, "name": "GPU fixture", "util": 51,
                                 "mem_used": 2 * 1024**3, "mem_total": 24 * 1024**3}],
                    "recent": [{"time": 100, "finish": "stop", "output_tokens": 20}],
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with urlopen(Request(f"http://127.0.0.1:{server.server_port}/v1/telemetry",
                                 headers={"Authorization": "Bearer fixture-key"}), timeout=2) as response:
                self.assertEqual(response.status, 200)
            env = os.environ.copy()
            env["STRATA_MONITOR_CREDENTIAL"] = "fixture-key"
            result = subprocess.run(
                [sys.executable, str(SOURCE), "--strata-root", str(strata_root),
                 "--port", str(server.server_port)],
                env=env, capture_output=True, text=True, encoding="utf-8", timeout=10, check=True,
            )
            output = json.loads(result.stdout)
            self.assertTrue(output["ok"], output)
            self.assertEqual(output["answer_tok_s"], 37.5)
            self.assertEqual(output["devices"][0]["mem_used"], 2 * 1024**3)
            self.assertEqual(output["recent"][0]["output_tokens"], 20)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
