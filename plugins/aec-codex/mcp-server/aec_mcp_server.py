#!/usr/bin/env python3
"""Dependency-free STDIO MCP host for local AEC Codex connectors."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

# CPython's Windows embeddable distribution runs with an explicit ``._pth``
# file and does not automatically add the launched script's directory. Keep
# sibling modules importable in both the private runtime and normal dev Python.
SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

from provider_gateway import MANAGER as PROVIDERS, ProviderError


SERVER_VERSION = "1.1.0-rc.3"
SUPPORTED_MCP_VERSIONS = (
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
)
LATEST_MCP_VERSION = SUPPORTED_MCP_VERSIONS[0]
TERMINAL_STATUSES = {"succeeded", "failed", "rejected", "expired", "cancelled"}
APPLICATIONS = {"revit", "autocad"}
MAX_DESCRIPTOR_BYTES = 64 * 1024


TARGET_PROPERTIES = {
    "instanceId": {
        "type": "string",
        "description": "Exact connector instance ID. Prefer this when several sessions are open.",
    },
    "application": {
        "type": "string",
        "enum": ["revit", "autocad"],
        "description": "Limit routing to Revit or AutoCAD.",
    },
    "applicationVersion": {
        "type": "string",
        "pattern": "^[0-9]{4}$",
        "description": "Optional Autodesk major version, such as 2024 or 2027.",
    },
    "documentTitle": {
        "type": "string",
        "description": "Optional exact active document title.",
    },
}


def object_schema(
    properties: dict[str, Any], required: list[str] | None = None
) -> dict[str, Any]:
    schema: dict[str, Any] = {
        "type": "object",
        "properties": properties,
        "additionalProperties": False,
    }
    if required:
        schema["required"] = required
    return schema


TOOLS = [
    {
        "name": "aec_list_instances",
        "title": "List Autodesk sessions",
        "description": "List discoverable local Revit and AutoCAD connector sessions.",
        "inputSchema": object_schema(
            {
                "application": TARGET_PROPERTIES["application"],
                "applicationVersion": TARGET_PROPERTIES["applicationVersion"],
            }
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_get_document_info",
        "title": "Get Autodesk document information",
        "description": "Read application, connector, active document, and capability information.",
        "inputSchema": object_schema(TARGET_PROPERTIES),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_get_selection",
        "title": "Get Autodesk selection",
        "description": "Read the current Revit element or AutoCAD entity selection.",
        "inputSchema": object_schema(TARGET_PROPERTIES),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_execute_read",
        "title": "Execute read-only Autodesk API code",
        "description": "Run bounded read-only code in one selected Revit or AutoCAD session.",
        "inputSchema": object_schema(
            {
                **TARGET_PROPERTIES,
                "description": {
                    "type": "string",
                    "description": "Short explanation of the information being read.",
                },
                "code": {
                    "type": "string",
                    "description": "C# method-body code. Revit exposes uiApp, uiDoc, doc, and transaction; AutoCAD exposes document, database, editor, and transaction. Return a JSON-serializable value.",
                },
                "timeoutSeconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 300,
                    "default": 30,
                },
            },
            ["description", "code"],
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_execute_write",
        "title": "Execute Autodesk API write code",
        "description": (
            "Run bounded application-specific write code in a native transaction. "
            "Arbitrary write code is potentially destructive."
        ),
        "inputSchema": object_schema(
            {
                **TARGET_PROPERTIES,
                "description": {
                    "type": "string",
                    "description": "Short explanation of the requested model or drawing change.",
                },
                "code": {
                    "type": "string",
                    "description": "C# method-body code executed inside one native write transaction. Revit exposes uiApp, uiDoc, doc, and transaction; AutoCAD exposes document, database, editor, and transaction. Do not commit or start another top-level transaction.",
                },
                "timeoutSeconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 300,
                    "default": 30,
                },
            },
            ["description", "code"],
        ),
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": True,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_list_providers",
        "title": "List structured AEC providers",
        "description": "List installed Revit and AutoCAD structured-tool providers and optionally probe their health.",
        "inputSchema": object_schema(
            {
                "probe": {
                    "type": "boolean",
                    "default": False,
                    "description": "Start providers and count tools. This can take several seconds.",
                }
            }
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_search_provider_tools",
        "title": "Search structured Autodesk tools",
        "description": "Search installed provider catalogs without loading every tool schema into context.",
        "inputSchema": object_schema(
            {
                "query": {"type": "string", "description": "Capability or Autodesk command to find."},
                "provider": {"type": "string", "description": "Optional provider id."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 25, "default": 10},
            },
            ["query"],
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_get_provider_tool_schema",
        "title": "Get structured Autodesk tool schema",
        "description": "Get the exact input schema and access classification for one provider tool before calling it.",
        "inputSchema": object_schema(
            {
                "provider": {"type": "string"},
                "toolName": {"type": "string"},
            },
            ["provider", "toolName"],
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_call_provider_read",
        "title": "Call structured read-only Autodesk tool",
        "description": "Call one provider tool only when the provider catalog classifies it as read-only.",
        "inputSchema": object_schema(
            {
                "provider": {"type": "string"},
                "toolName": {"type": "string"},
                "arguments": {"type": "object", "additionalProperties": True},
                "timeoutSeconds": {"type": "integer", "minimum": 1, "maximum": 300, "default": 60},
            },
            ["provider", "toolName", "arguments"],
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_call_provider_write",
        "title": "Call structured Autodesk write tool",
        "description": "Preview or execute one structured provider write tool. A gateway preview never calls an upstream tool that lacks native dry-run support.",
        "inputSchema": object_schema(
            {
                "provider": {"type": "string"},
                "toolName": {"type": "string"},
                "arguments": {"type": "object", "additionalProperties": True},
                "dryRun": {"type": "boolean", "default": True},
                "timeoutSeconds": {"type": "integer", "minimum": 1, "maximum": 300, "default": 60},
            },
            ["provider", "toolName", "arguments", "dryRun"],
        ),
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": True,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
]
TOOL_BY_NAME = {tool["name"]: tool for tool in TOOLS}


class ProtocolError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class ToolInputError(ValueError):
    pass


def instance_directory() -> Path:
    configured = os.environ.get("AEC_CODEX_INSTANCE_DIR")
    if configured:
        return Path(configured)
    app_data = os.environ.get("APPDATA", str(Path.home()))
    return Path(app_data) / "AEC Codex" / "instances"


def _validate_descriptor(value: Any, source: Path) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{source.name}: descriptor must be an object")
    required = {
        "protocolVersion",
        "instanceId",
        "application",
        "applicationVersion",
        "processId",
        "url",
        "token",
        "startedAtUtc",
        "capabilities",
    }
    missing = required - set(value)
    if missing:
        raise ValueError(f"{source.name}: missing {', '.join(sorted(missing))}")
    if value["protocolVersion"] != 1:
        raise ValueError(f"{source.name}: unsupported connector protocol")
    if not isinstance(value["instanceId"], str) or not value["instanceId"]:
        raise ValueError(f"{source.name}: invalid instanceId")
    if value["application"] not in APPLICATIONS:
        raise ValueError(f"{source.name}: invalid application")
    version = value["applicationVersion"]
    if not isinstance(version, str) or len(version) != 4 or not version.isdigit():
        raise ValueError(f"{source.name}: invalid applicationVersion")
    if isinstance(value["processId"], bool) or not isinstance(value["processId"], int):
        raise ValueError(f"{source.name}: invalid processId")
    if value["processId"] < 1:
        raise ValueError(f"{source.name}: invalid processId")
    parsed = urllib.parse.urlsplit(value["url"])
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or parsed.port is None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError(f"{source.name}: connector URL must be loopback HTTP")
    if not isinstance(value["token"], str) or len(value["token"]) < 32:
        raise ValueError(f"{source.name}: invalid token")
    if not isinstance(value["capabilities"], list) or not all(
        isinstance(item, str) and item for item in value["capabilities"]
    ):
        raise ValueError(f"{source.name}: invalid capabilities")
    document = value.get("document")
    if document is not None and not isinstance(document, dict):
        raise ValueError(f"{source.name}: invalid document")
    return value


def load_instances() -> tuple[list[dict[str, Any]], list[str]]:
    directory = instance_directory()
    if not directory.exists():
        return [], []
    instances: list[dict[str, Any]] = []
    warnings: list[str] = []
    for path in sorted(directory.glob("*.json")):
        try:
            if path.stat().st_size > MAX_DESCRIPTOR_BYTES:
                raise ValueError(f"{path.name}: descriptor is too large")
            value = json.loads(path.read_text(encoding="utf-8-sig"))
            instances.append(_validate_descriptor(value, path))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            warnings.append(str(exc))
    return instances, warnings


def public_instance(instance: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in instance.items() if key != "token"}


def _target_filters(arguments: dict[str, Any]) -> dict[str, str]:
    filters: dict[str, str] = {}
    for key in ("instanceId", "application", "applicationVersion", "documentTitle"):
        value = arguments.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or not value.strip():
            raise ToolInputError(f"{key} must be a non-empty string")
        filters[key] = value.strip()
    if "application" in filters and filters["application"] not in APPLICATIONS:
        raise ToolInputError("application must be revit or autocad")
    version = filters.get("applicationVersion")
    if version and (len(version) != 4 or not version.isdigit()):
        raise ToolInputError("applicationVersion must be a four-digit year")
    return filters


def select_instance(arguments: dict[str, Any]) -> dict[str, Any]:
    filters = _target_filters(arguments)
    instances, warnings = load_instances()
    matches = []
    for instance in instances:
        document = instance.get("document") or {}
        if filters.get("instanceId") not in {None, instance["instanceId"]}:
            continue
        if filters.get("application") not in {None, instance["application"]}:
            continue
        if filters.get("applicationVersion") not in {None, instance["applicationVersion"]}:
            continue
        if filters.get("documentTitle") not in {None, document.get("title")}:
            continue
        matches.append(instance)
    if len(matches) == 1:
        return matches[0]
    if not matches:
        suffix = f" Invalid descriptors: {'; '.join(warnings)}" if warnings else ""
        raise RuntimeError("No matching Revit or AutoCAD connector is running." + suffix)
    choices = [public_instance(item) for item in matches]
    raise RuntimeError(
        "More than one connector matches. Pass instanceId explicitly: "
        + json.dumps(choices, ensure_ascii=False)
    )


def connector_request(
    instance: dict[str, Any],
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
    timeout: float = 10,
) -> dict[str, Any]:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        instance["url"].rstrip("/") + path,
        data=body,
        method=method,
        headers={
            "Authorization": "Bearer " + instance["token"],
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:2000]
        raise RuntimeError(f"Connector HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError("Connector is unavailable: " + str(exc.reason)) from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError("Connector returned invalid JSON") from exc
    if not isinstance(result, dict):
        raise RuntimeError("Connector response must be a JSON object")
    return result


def _validate_call_arguments(name: str, arguments: Any) -> dict[str, Any]:
    if not isinstance(arguments, dict):
        raise ToolInputError("Tool arguments must be a JSON object")
    schema_properties = TOOL_BY_NAME[name]["inputSchema"]["properties"]
    unknown = set(arguments) - set(schema_properties)
    if unknown:
        raise ToolInputError("Unknown argument(s): " + ", ".join(sorted(unknown)))
    if name in {"aec_get_document_info", "aec_get_selection", "aec_execute_read", "aec_execute_write"}:
        _target_filters(arguments)
    if name.startswith("aec_execute_"):
        for key in ("description", "code"):
            value = arguments.get(key)
            if not isinstance(value, str) or not value.strip():
                raise ToolInputError(f"{key} is required and must be a non-empty string")
        timeout = arguments.get("timeoutSeconds", 30)
        if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= 300:
            raise ToolInputError("timeoutSeconds must be an integer from 1 through 300")
    if name in {"aec_search_provider_tools", "aec_get_provider_tool_schema", "aec_call_provider_read", "aec_call_provider_write"}:
        for key in ("provider", "toolName"):
            if key in arguments and (not isinstance(arguments[key], str) or not arguments[key].strip()):
                raise ToolInputError(f"{key} must be a non-empty string")
    if name == "aec_search_provider_tools":
        query = arguments.get("query")
        if not isinstance(query, str) or not query.strip():
            raise ToolInputError("query is required")
        limit = arguments.get("limit", 10)
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 25:
            raise ToolInputError("limit must be an integer from 1 through 25")
    if name.startswith("aec_call_provider_"):
        if not isinstance(arguments.get("arguments"), dict):
            raise ToolInputError("arguments must be an object")
        timeout = arguments.get("timeoutSeconds", 60)
        if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= 300:
            raise ToolInputError("timeoutSeconds must be an integer from 1 through 300")
    if name == "aec_call_provider_write" and not isinstance(arguments.get("dryRun"), bool):
        raise ToolInputError("dryRun is required and must be boolean")
    return arguments


def _list_instances(arguments: dict[str, Any]) -> dict[str, Any]:
    filters = _target_filters(arguments)
    instances, warnings = load_instances()
    visible = []
    for instance in instances:
        if filters.get("application") not in {None, instance["application"]}:
            continue
        if filters.get("applicationVersion") not in {None, instance["applicationVersion"]}:
            continue
        visible.append(public_instance(instance))
    return {"instances": visible, "warnings": warnings}


def _execute(instance: dict[str, Any], arguments: dict[str, Any], mode: str) -> dict[str, Any]:
    timeout_seconds = arguments.get("timeoutSeconds", 30)
    payload = {
        "mode": mode,
        "description": arguments["description"].strip(),
        "code": arguments["code"].strip(),
        "timeoutSeconds": timeout_seconds,
    }
    created = connector_request(instance, "POST", "/v1/execute", payload)
    if created.get("status") in TERMINAL_STATUSES:
        return created
    request_id = created.get("requestId")
    if not isinstance(request_id, str) or not request_id:
        raise RuntimeError("Connector did not return a requestId")
    deadline = time.monotonic() + timeout_seconds + 15
    while time.monotonic() < deadline:
        result = connector_request(instance, "GET", "/v1/requests/" + request_id)
        if result.get("status") in TERMINAL_STATUSES:
            return result
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for connector request {request_id}")


def _require_unambiguous_provider_session(provider_id: str) -> None:
    application = PROVIDERS.get(provider_id).descriptor.get("application")
    if application not in APPLICATIONS:
        return
    instances, _warnings = load_instances()
    matching = [item for item in instances if item.get("application") == application]
    if len(matching) > 1:
        raise RuntimeError(
            f"{provider_id} cannot target one of several {application} sessions safely. "
            "Close the extra sessions or use the instance-aware AEC Codex connector fallback."
        )


def invoke_tool(name: str, arguments: Any) -> dict[str, Any]:
    if name not in TOOL_BY_NAME:
        raise ToolInputError("Unknown tool: " + name)
    values = _validate_call_arguments(name, arguments)
    if name == "aec_list_providers":
        return PROVIDERS.list(probe=values.get("probe", False))
    if name == "aec_search_provider_tools":
        return PROVIDERS.search(
            values["query"].strip(), values.get("provider"), values.get("limit", 10)
        )
    if name == "aec_get_provider_tool_schema":
        return PROVIDERS.schema(values["provider"].strip(), values["toolName"].strip())
    if name in {"aec_call_provider_read", "aec_call_provider_write"}:
        access = "read" if name.endswith("_read") else "write"
        _require_unambiguous_provider_session(values["provider"].strip())
        return PROVIDERS.invoke(
            values["provider"].strip(),
            values["toolName"].strip(),
            values["arguments"],
            access,
            values.get("dryRun", False),
            values.get("timeoutSeconds", 60),
        )
    if name == "aec_list_instances":
        return _list_instances(values)
    instance = select_instance(values)
    if name == "aec_get_document_info":
        return connector_request(instance, "GET", "/v1/info")
    if name == "aec_get_selection":
        return connector_request(instance, "GET", "/v1/selection")
    mode = "read" if name == "aec_execute_read" else "write"
    return _execute(instance, values, mode)


def tool_result(value: dict[str, Any], is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}],
        "structuredContent": value,
        "isError": is_error,
    }


def handle(message: Any) -> dict[str, Any] | None:
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        raise ProtocolError(-32600, "Invalid JSON-RPC request")
    method = message.get("method")
    if not isinstance(method, str):
        raise ProtocolError(-32600, "JSON-RPC method must be a string")
    params = message.get("params") or {}
    if not isinstance(params, dict):
        raise ProtocolError(-32602, "params must be an object")
    request_id = message.get("id")
    if method == "initialize":
        requested = params.get("protocolVersion")
        if not isinstance(requested, str):
            raise ProtocolError(-32602, "initialize requires protocolVersion")
        negotiated = requested if requested in SUPPORTED_MCP_VERSIONS else LATEST_MCP_VERSION
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": negotiated,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {
                    "name": "aec-codex",
                    "version": SERVER_VERSION,
                    "description": "Local MCP host for Revit and AutoCAD connectors",
                },
                "instructions": (
                    "List instances before the first Autodesk operation. Read before writing, "
                    "route to an explicit instance when multiple sessions match, and never "
                    "send a write through a read-only tool."
                ),
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}
    if method.startswith("notifications/"):
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name")
        if not isinstance(name, str):
            raise ProtocolError(-32602, "tools/call requires a tool name")
        try:
            value = invoke_tool(name, params.get("arguments", {}))
        except (ToolInputError, ProviderError, RuntimeError, KeyError, ValueError) as exc:
            result = tool_result({"error": str(exc)}, is_error=True)
        else:
            result = tool_result(value, is_error=value.get("status") in TERMINAL_STATUSES - {"succeeded"})
        return {"jsonrpc": "2.0", "id": request_id, "result": result}
    raise ProtocolError(-32601, "Method not found")


def error_response(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def process_message(message: Any) -> dict[str, Any] | None:
    request_id = message.get("id") if isinstance(message, dict) else None
    try:
        return handle(message)
    except ProtocolError as exc:
        return error_response(request_id, exc.code, exc.message)
    except Exception as exc:
        return error_response(request_id, -32603, "Internal error: " + str(exc))


def process_payload(payload: Any) -> dict[str, Any] | list[dict[str, Any]] | None:
    if isinstance(payload, list):
        if not payload:
            return error_response(None, -32600, "Empty JSON-RPC batch")
        responses = [result for item in payload if (result := process_message(item)) is not None]
        return responses or None
    return process_message(payload)


def main() -> None:
    if hasattr(sys.stdin, "reconfigure"):
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    for raw in sys.stdin:
        if not raw.strip():
            continue
        try:
            response = process_payload(json.loads(raw))
        except json.JSONDecodeError as exc:
            response = error_response(None, -32700, "Parse error: " + str(exc))
        if response is not None:
            print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
