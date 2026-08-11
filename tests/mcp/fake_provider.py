from __future__ import annotations

import json
import sys


TOOLS = [
    {
        "name": "get_model_info",
        "description": "Read structured model information",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "create_wall",
        "description": "Create a structured wall",
        "inputSchema": {
            "type": "object",
            "properties": {"length": {"type": "number"}, "dryRun": {"type": "boolean"}},
            "required": ["length"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
    },
    {
        "name": "set_name",
        "description": "Set an object name without native preview support.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False},
    },
    {
        "name": "send_code_to_revit",
        "description": "Blocked arbitrary code",
        "inputSchema": {"type": "object"},
    },
]


for raw in sys.stdin:
    try:
        message = json.loads(raw)
        method = message.get("method")
        if method == "initialize":
            result = {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fake-provider", "version": "1.0.0"},
            }
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            arguments = message["params"].get("arguments", {})
            result = {
                "content": [{"type": "text", "text": json.dumps(arguments)}],
                "structuredContent": {"called": message["params"]["name"], "arguments": arguments},
                "isError": False,
            }
        elif method and method.startswith("notifications/"):
            continue
        else:
            result = {}
        if "id" in message:
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
    except Exception as exc:
        print(
            json.dumps(
                {"jsonrpc": "2.0", "id": message.get("id"), "error": {"code": -32000, "message": str(exc)}}
            ),
            flush=True,
        )
