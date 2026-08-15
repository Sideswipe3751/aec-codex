from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SERVER_PATH = REPOSITORY_ROOT / "plugins" / "aec-codex" / "mcp-server" / "aec_mcp_server.py"


class CodexMcpAdapterTests(unittest.TestCase):
    def test_skill_bootstraps_each_relevant_task_without_claiming_an_idle_hook(self):
        skill = (REPOSITORY_ROOT / "plugins" / "aec-codex" / "skills" / "aec-codex" / "SKILL.md").read_text(encoding="utf-8")
        metadata = (REPOSITORY_ROOT / "plugins" / "aec-codex" / "skills" / "aec-codex" / "agents" / "openai.yaml").read_text(encoding="utf-8")

        self.assertIn("first activation in every relevant task", skill)
        self.assertIn("../../scripts/Get-AecCodexHostStatus.ps1", skill)
        self.assertIn("does not create a background hook", skill)
        self.assertIn("allow_implicit_invocation: true", metadata)

    def test_stdio_adapter_projects_the_frozen_v1_surface_from_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["AEC_CODEX_INSTANCE_DIR"] = str(Path(temporary) / "instances")
            environment["AEC_CODEX_RUNTIME_ROOT"] = str(REPOSITORY_ROOT / "runtime")
            environment["AEC_CODEX_PROVIDER_CONFIG"] = str(Path(temporary) / "providers.json")
            process = subprocess.Popen(
                [sys.executable, str(SERVER_PATH)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                env=environment,
            )
            assert process.stdin is not None
            assert process.stdout is not None
            try:
                def request(payload: dict[str, object]) -> dict[str, object]:
                    process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
                    process.stdin.flush()
                    line = process.stdout.readline()
                    self.assertTrue(line, "MCP adapter exited before responding")
                    return json.loads(line)

                initialized = request(
                    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "contract-test", "version": "1"}}}
                )
                process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, separators=(",", ":")) + "\n")
                process.stdin.flush()
                tools = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
                listed = request(
                    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "aec_list_instances", "arguments": {"application": "revit", "applicationVersion": "2027"}}}
                )
                self.assertEqual("1.1.0-rc.3", initialized["result"]["serverInfo"]["version"])
                self.assertEqual(10, len(tools["result"]["tools"]))
                structured = listed["result"]["structuredContent"]
                self.assertEqual([], structured["instances"])
                self.assertEqual([], structured["warnings"])
            finally:
                process.stdin.close()
                process.wait(timeout=10)
                process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()

    def test_adapter_no_longer_owns_host_discovery_or_http_polling(self) -> None:
        source = SERVER_PATH.read_text(encoding="utf-8")
        self.assertNotIn("def select_instance(", source)
        self.assertNotIn("def connector_request(", source)
        self.assertNotIn("urllib.request", source)
        self.assertIn("from aec_runtime import", source)
        self.assertNotIn("PROVIDERS.invoke", source)
        self.assertNotIn("def _require_unambiguous_provider_session", source)
        self.assertIn("RUNTIME.invoke_provider", source)


if __name__ == "__main__":
    unittest.main()
