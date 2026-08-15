from __future__ import annotations

import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "runtime"))

from aec_runtime.hosts import (  # noqa: E402
    TargetInputError,
    execute_connector_request,
    load_instances,
    normalize_target_filters,
    public_instance,
    select_exact_target,
    select_instance,
)


def descriptor(instance_id: str, port: int = 4821) -> dict[str, object]:
    return {
        "protocolVersion": 1,
        "instanceId": instance_id,
        "application": "revit",
        "applicationVersion": "2027",
        "processId": 1234,
        "url": f"http://127.0.0.1:{port}",
        "token": "t" * 32,
        "startedAtUtc": "2026-08-14T00:00:00Z",
        "document": {"id": "path:c:/test.rvt", "title": "test.rvt", "path": "C:/test.rvt"},
        "capabilities": ["document.info", "code.read"],
    }


class ConnectorHandler(BaseHTTPRequestHandler):
    polls = 0
    last_payload: dict[str, object] | None = None
    token = "t" * 32

    def log_message(self, format: str, *args: object) -> None:
        pass

    def _json(self, status: int, value: object) -> None:
        body = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        return self.headers.get("Authorization") == "Bearer " + self.token

    def do_POST(self) -> None:
        if not self._authorized():
            self._json(401, {"error": "unauthorized"})
            return
        if self.path == "/v1/execute":
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length))
            type(self).last_payload = payload
            if payload["mode"] != "read":
                self._json(400, {"error": "invalid_mode"})
                return
            self._json(202, {"requestId": "request-1", "status": "queued"})
            return
        self._json(404, {"error": "not_found"})

    def do_GET(self) -> None:
        if not self._authorized():
            self._json(401, {"error": "unauthorized"})
            return
        if self.path == "/v1/requests/request-1":
            type(self).polls += 1
            if type(self).polls == 1:
                self._json(200, {"requestId": "request-1", "status": "running"})
            else:
                self._json(200, {"requestId": "request-1", "status": "succeeded", "result": {"value": 7}})
            return
        self._json(404, {"error": "not_found"})


class HostRuntimeTests(unittest.TestCase):
    def test_descriptor_discovery_filters_invalid_files_and_hides_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "valid.json").write_text(json.dumps(descriptor("revit-2027-1234")), encoding="utf-8")
            (root / "invalid.json").write_text("{not-json", encoding="utf-8")
            instances, warnings = load_instances(root)
            self.assertEqual(1, len(instances))
            self.assertEqual(1, len(warnings))
            self.assertNotIn("token", public_instance(instances[0]))

    def test_target_selection_requires_explicit_instance_when_ambiguous(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index in (1, 2):
                (root / f"{index}.json").write_text(json.dumps(descriptor(f"revit-2027-{index}")), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "Pass instanceId explicitly"):
                select_instance({"application": "revit", "applicationVersion": "2027"}, root)
            selected = select_instance({"instanceId": "revit-2027-2"}, root)
            self.assertEqual("revit-2027-2", selected["instanceId"])

    def test_target_filters_reject_malformed_values(self) -> None:
        with self.assertRaises(TargetInputError):
            normalize_target_filters({"applicationVersion": "27"})
        with self.assertRaises(TargetInputError):
            normalize_target_filters({"application": "inventor"})

    def test_exact_target_rejects_document_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            value = descriptor("revit-2027-1234")
            (root / "instance.json").write_text(json.dumps(value), encoding="utf-8")
            target = {
                "application": "revit",
                "release": "2027",
                "apiVariant": "2027",
                "instanceId": "revit-2027-1234",
                "processId": 1234,
                "document": dict(value["document"]),
            }
            self.assertEqual("revit-2027-1234", select_exact_target(target, root)["instanceId"])
            target["document"]["id"] = "path:c:/another.rvt"
            with self.assertRaisesRegex(RuntimeError, "no longer available"):
                select_exact_target(target, root)

    def test_connector_execution_preserves_v1_queue_and_poll_behavior(self) -> None:
        ConnectorHandler.polls = 0
        ConnectorHandler.last_payload = None
        server = ThreadingHTTPServer(("127.0.0.1", 0), ConnectorHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            instance = descriptor("revit-2027-1234", server.server_port)
            result = execute_connector_request(
                instance,
                {"description": "Read test value", "code": "return 7;", "timeoutSeconds": 2},
                "read",
            )
            self.assertEqual("succeeded", result["status"])
            self.assertEqual(7, result["result"]["value"])
            self.assertEqual(2, ConnectorHandler.polls)
            self.assertEqual("revit-2027-1234", ConnectorHandler.last_payload["target"]["instanceId"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_client_timeout_requests_connector_cancellation(self) -> None:
        instance = descriptor("revit-2027-1234")
        with patch(
            "aec_runtime.hosts.connector_request",
            side_effect=[
                {"requestId": "request-timeout", "status": "queued"},
                {"requestId": "request-timeout", "status": "cancelled"},
            ],
        ) as request_call, patch("aec_runtime.hosts.time.monotonic", side_effect=[0.0, 20.0]):
            with self.assertRaisesRegex(RuntimeError, "cancellation requested"):
                execute_connector_request(
                    instance,
                    {"description": "Timeout", "code": "return 7;", "timeoutSeconds": 2},
                    "read",
                )
        self.assertEqual("/v1/requests/request-timeout/cancel", request_call.call_args_list[-1].args[2])


if __name__ == "__main__":
    unittest.main()
