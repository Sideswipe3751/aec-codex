from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SERVER_PATH = (
    Path(__file__).parents[2]
    / "plugins"
    / "aec-codex"
    / "mcp-server"
    / "aec_mcp_server.py"
)
SPEC = importlib.util.spec_from_file_location("aec_mcp_server", SERVER_PATH)
assert SPEC and SPEC.loader
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


class FakeConnector(BaseHTTPRequestHandler):
    token = "t" * 48
    last_execute = None

    def log_message(self, *_args):
        pass

    def _authorized(self):
        return self.headers.get("Authorization") == "Bearer " + self.token

    def _write(self, status, value):
        body = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._authorized():
            self._write(401, {"error": "unauthorized"})
        elif self.path == "/v1/info":
            self._write(200, {"application": "revit", "version": "2024", "document": "Test"})
        elif self.path == "/v1/selection":
            self._write(200, {"ids": [42]})
        elif self.path == "/v1/requests/request-1":
            self._write(200, {"requestId": "request-1", "status": "succeeded", "result": {"ok": True}})
        else:
            self._write(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized():
            self._write(401, {"error": "unauthorized"})
            return
        size = int(self.headers.get("Content-Length", "0"))
        FakeConnector.last_execute = json.loads(self.rfile.read(size).decode("utf-8"))
        self._write(202, {"requestId": "request-1", "status": "queued"})


class McpServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = os.environ.get("AEC_CODEX_INSTANCE_DIR")
        os.environ["AEC_CODEX_INSTANCE_DIR"] = self.temp.name
        self.http = ThreadingHTTPServer(("127.0.0.1", 0), FakeConnector)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.write_descriptor("revit-one", self.http.server_port)

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=2)
        if self.previous is None:
            os.environ.pop("AEC_CODEX_INSTANCE_DIR", None)
        else:
            os.environ["AEC_CODEX_INSTANCE_DIR"] = self.previous
        self.temp.cleanup()

    def write_descriptor(self, instance_id, port, url=None):
        value = {
            "protocolVersion": 1,
            "instanceId": instance_id,
            "application": "revit",
            "applicationVersion": "2024",
            "processId": 1234,
            "url": url or f"http://127.0.0.1:{port}",
            "token": FakeConnector.token,
            "startedAtUtc": "2026-08-10T00:00:00Z",
            "document": {"id": "doc-1", "title": "Test", "path": None},
            "capabilities": ["document.info", "selection.read", "code.read", "code.write"],
        }
        Path(self.temp.name, instance_id + ".json").write_text(json.dumps(value), encoding="utf-8")

    def test_tool_annotations_separate_read_and_write(self):
        tools = {item["name"]: item for item in MCP.TOOLS}
        self.assertTrue(tools["aec_execute_read"]["annotations"]["readOnlyHint"])
        self.assertFalse(tools["aec_execute_write"]["annotations"]["readOnlyHint"])
        self.assertTrue(tools["aec_execute_write"]["annotations"]["destructiveHint"])

    def test_list_does_not_expose_token(self):
        result = MCP.invoke_tool("aec_list_instances", {})
        self.assertEqual(1, len(result["instances"]))
        self.assertNotIn("token", result["instances"][0])

    def test_document_and_selection_proxy(self):
        info = MCP.invoke_tool("aec_get_document_info", {"instanceId": "revit-one"})
        selection = MCP.invoke_tool("aec_get_selection", {"instanceId": "revit-one"})
        self.assertEqual("Test", info["document"])
        self.assertEqual([42], selection["ids"])

    def test_execute_modes_are_forced_by_tool(self):
        arguments = {"instanceId": "revit-one", "description": "Read title", "code": "return doc.Title;"}
        result = MCP.invoke_tool("aec_execute_read", arguments)
        self.assertEqual("succeeded", result["status"])
        self.assertEqual("read", FakeConnector.last_execute["mode"])
        arguments["description"] = "Change model"
        MCP.invoke_tool("aec_execute_write", arguments)
        self.assertEqual("write", FakeConnector.last_execute["mode"])

    def test_ambiguous_routing_requires_instance_id(self):
        self.write_descriptor("revit-two", self.http.server_port)
        with self.assertRaisesRegex(RuntimeError, "More than one connector"):
            MCP.invoke_tool("aec_get_document_info", {"application": "revit"})

    def test_non_loopback_descriptor_is_ignored(self):
        self.write_descriptor("bad", self.http.server_port, "http://example.com:1234")
        result = MCP.invoke_tool("aec_list_instances", {})
        self.assertEqual(1, len(result["instances"]))
        self.assertTrue(any("loopback" in warning for warning in result["warnings"]))

    def test_json_rpc_initialize_and_tools_list(self):
        initialized = MCP.process_message(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}}
        )
        listed = MCP.process_message({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual("aec-codex", initialized["result"]["serverInfo"]["name"])
        self.assertEqual(5, len(listed["result"]["tools"]))


if __name__ == "__main__":
    unittest.main()
