#!/usr/bin/env python3
"""Export stable child-MCP tool schemas and optionally compare a prior snapshot."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "plugins" / "aec-codex" / "mcp-server"
sys.path.insert(0, str(SERVER))

from provider_gateway import ProviderError, ProviderManager  # noqa: E402


def collect(manager: ProviderManager) -> dict[str, Any]:
    manager.reload(force=True)
    providers: list[dict[str, Any]] = []
    for provider_id, child in sorted(manager.providers.items()):
        tools = []
        for tool in sorted(child.tools(refresh=True), key=lambda item: str(item.get("name", ""))):
            tools.append(
                {
                    "name": tool.get("name"),
                    "description": tool.get("description", ""),
                    "inputSchema": tool.get("inputSchema", {}),
                    "annotations": tool.get("annotations", {}),
                }
            )
        providers.append(
            {
                "id": provider_id,
                "version": child.descriptor.get("version"),
                "tools": tools,
            }
        )
    return {"schemaVersion": 1, "providers": providers}


def tool_index(snapshot: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result = {}
    for provider in snapshot.get("providers", []):
        for tool in provider.get("tools", []):
            result[f"{provider.get('id')}.{tool.get('name')}"] = tool
    return result


def compare(old: dict[str, Any], new: dict[str, Any]) -> dict[str, Any]:
    before = tool_index(old)
    after = tool_index(new)
    common = before.keys() & after.keys()
    return {
        "added": sorted(after.keys() - before.keys()),
        "removed": sorted(before.keys() - after.keys()),
        "changed": sorted(
            name for name in common if before[name] != after[name]
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()
    if args.config:
        os.environ["AEC_CODEX_PROVIDER_CONFIG"] = str(args.config.resolve())
    manager = ProviderManager()
    try:
        snapshot = collect(manager)
    except ProviderError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        manager.close()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    if args.compare:
        old = json.loads(args.compare.read_text(encoding="utf-8-sig"))
        print(json.dumps(compare(old, snapshot), ensure_ascii=False, indent=2))
    else:
        counts = {item["id"]: len(item["tools"]) for item in snapshot["providers"]}
        print(json.dumps({"output": str(args.output), "toolCounts": counts}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
