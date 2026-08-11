#!/usr/bin/env python3
"""Initialize the packaged upstream MCPs and export their advertised schemas."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "plugins" / "aec-codex" / "mcp-server"))

from provider_gateway import ProviderManager  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", type=Path, default=ROOT / "artifacts" / "providers")
    parser.add_argument("--autocad-command", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    artifacts = args.artifacts.resolve()
    manifest = json.loads((artifacts / "build-manifest.json").read_text(encoding="utf-8-sig"))
    versions = {item["id"]: item["version"] for item in manifest["providers"]}
    revit = artifacts / "revit-community" / versions["revit-community"]
    config = {
        "schemaVersion": 1,
        "providers": [
            {
                "id": "revit-community",
                "application": "revit",
                "displayName": "mcp-servers-for-revit",
                "version": versions["revit-community"],
                "command": str(revit / "runtime" / "node" / "node.exe"),
                "args": [
                    str(
                        revit
                        / "server"
                        / "build"
                        / "index.js"
                    )
                ],
                "env": {"AEC_CODEX_PROVIDER_TOKEN": "test-token-" + "x" * 64},
            },
            {
                "id": "autocad-pro",
                "application": "autocad",
                "displayName": "U-C4N AutoCAD MCP",
                "version": versions["autocad-pro"],
                "command": str(args.autocad_command.resolve()),
                "args": [],
                "env": {
                    "AUTOCAD_MCP_BACKEND": "ezdxf",
                    "TOOL_PROFILE": "lean",
                    "ALLOWED_PATHS": str(ROOT),
                    "ALLOW_REMOTE_HTTP": "false",
                    "DANGEROUS_COMMANDS_ENABLED": "false",
                },
            },
        ],
    }
    with tempfile.TemporaryDirectory(prefix="aec-codex-provider-smoke-") as temp:
        config_path = Path(temp) / "active.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        os.environ["AEC_CODEX_PROVIDER_CONFIG"] = str(config_path)
        manager = ProviderManager()
        try:
            status = manager.list(probe=True)
            failures = [item for item in status["providers"] if item["status"] != "ready"]
            schemas = {
                "schemaVersion": 1,
                "providers": [
                    {
                        "id": provider_id,
                        "version": child.descriptor.get("version"),
                        "tools": sorted(child.tools(), key=lambda item: item.get("name", "")),
                    }
                    for provider_id, child in sorted(manager.providers.items())
                ],
            }
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(
                json.dumps(schemas, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
            print(json.dumps(status, ensure_ascii=False, indent=2))
            return 1 if failures else 0
        finally:
            manager.close()


if __name__ == "__main__":
    raise SystemExit(main())
