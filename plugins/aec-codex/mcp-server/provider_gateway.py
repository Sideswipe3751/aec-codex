"""Versioned child-MCP provider gateway for AEC Codex."""

from __future__ import annotations

import atexit
import json
import os
import queue
import re
import subprocess
import threading
import time
from pathlib import Path
from typing import Any


class ProviderError(RuntimeError):
    pass


BLOCKED_TOOLS = {
    "send_code_to_revit",
    "system_run_command",
    "system_run_lisp",
    "execute_lisp",
}
READ_PREFIXES = (
    "get_",
    "list_",
    "query_",
    "search_",
    "analyze_",
    "check_",
    "find_",
    "measure_",
    "inspect_",
    "read_",
    "view_",
)
READ_TOOL_NAMES = {
    "ai_element_filter",
    "clash_detection",
    "drawing_info",
    "entity_get",
    "entity_list",
    "layer_list",
    "system_status",
}


def provider_config_path() -> Path:
    configured = os.environ.get("AEC_CODEX_PROVIDER_CONFIG")
    if configured:
        return Path(configured)
    local = os.environ.get("LOCALAPPDATA", str(Path.home()))
    return Path(local) / "AEC Codex" / "providers" / "active.json"


def _require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ProviderError(f"{label} must be an object")
    return value


def _validate_preview_arguments(tool: dict[str, Any], arguments: dict[str, Any]) -> None:
    schema = tool.get("inputSchema")
    if not isinstance(schema, dict):
        return
    required = schema.get("required", [])
    if isinstance(required, list):
        missing = [name for name in required if name not in arguments]
        if missing:
            raise ProviderError("Missing required provider argument(s): " + ", ".join(missing))
    properties = schema.get("properties", {})
    if schema.get("additionalProperties") is False and isinstance(properties, dict):
        unknown = sorted(set(arguments) - set(properties))
        if unknown:
            raise ProviderError("Unknown provider argument(s): " + ", ".join(unknown))


class ChildMcpProcess:
    def __init__(self, descriptor: dict[str, Any]):
        self.descriptor = descriptor
        self.process: subprocess.Popen[str] | None = None
        self.pending: dict[int, queue.Queue[dict[str, Any]]] = {}
        self.pending_lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.next_id = 1
        self.reader: threading.Thread | None = None
        self.stderr_reader: threading.Thread | None = None
        self.stderr_tail: list[str] = []
        self.tools_cache: list[dict[str, Any]] | None = None

    @property
    def provider_id(self) -> str:
        return str(self.descriptor["id"])

    def _command(self) -> list[str]:
        command = self.descriptor.get("command")
        args = self.descriptor.get("args", [])
        if not isinstance(command, str) or not command:
            raise ProviderError(f"Provider {self.provider_id} has no command")
        if not isinstance(args, list) or not all(isinstance(item, str) for item in args):
            raise ProviderError(f"Provider {self.provider_id} args are invalid")
        if ("/" in command or "\\" in command) and not Path(command).is_file():
            raise ProviderError(f"Provider executable is missing: {command}")
        return [command, *args]

    def start(self) -> None:
        if self.process and self.process.poll() is None:
            return
        environment = os.environ.copy()
        extra_env = self.descriptor.get("env", {})
        if not isinstance(extra_env, dict) or not all(
            isinstance(key, str) and isinstance(value, str)
            for key, value in extra_env.items()
        ):
            raise ProviderError(f"Provider {self.provider_id} env is invalid")
        environment.update(extra_env)
        try:
            self.process = subprocess.Popen(
                self._command(),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                env=environment,
                cwd=self.descriptor.get("cwd") or None,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except OSError as exc:
            raise ProviderError(f"Unable to start provider {self.provider_id}: {exc}") from exc
        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self.reader.start()
        self.stderr_reader.start()
        timeout = int(self.descriptor.get("startupTimeoutSeconds", 30))
        try:
            self.call(
                "initialize",
                {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "aec-codex-gateway", "version": "1.1.0"},
                },
                timeout=timeout,
            )
            self.notify("notifications/initialized", {})
        except Exception:
            self.close()
            raise

    def _read_stdout(self) -> None:
        assert self.process and self.process.stdout
        for raw in self.process.stdout:
            raw = raw.strip()
            if not raw:
                continue
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(message, dict) or "id" not in message:
                continue
            with self.pending_lock:
                waiter = self.pending.get(message["id"])
            if waiter:
                waiter.put(message)
        self._fail_pending("Provider process stopped")

    def _read_stderr(self) -> None:
        assert self.process and self.process.stderr
        for raw in self.process.stderr:
            line = raw.strip()
            if not line:
                continue
            self.stderr_tail.append(line[:1000])
            del self.stderr_tail[:-20]

    def _fail_pending(self, message: str) -> None:
        with self.pending_lock:
            waiters = list(self.pending.values())
        for waiter in waiters:
            waiter.put({"error": {"code": -32000, "message": message}})

    def _send(self, message: dict[str, Any]) -> None:
        if not self.process or self.process.poll() is not None or not self.process.stdin:
            detail = "; ".join(self.stderr_tail[-3:])
            suffix = f" ({detail})" if detail else ""
            raise ProviderError(f"Provider {self.provider_id} is not running{suffix}")
        encoded = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
        with self.write_lock:
            self.process.stdin.write(encoded + "\n")
            self.process.stdin.flush()

    def call(self, method: str, params: dict[str, Any], timeout: int = 60) -> Any:
        self.next_id += 1
        request_id = self.next_id
        waiter: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
        with self.pending_lock:
            self.pending[request_id] = waiter
        try:
            self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            try:
                response = waiter.get(timeout=timeout)
            except queue.Empty as exc:
                raise ProviderError(
                    f"Provider {self.provider_id} timed out during {method}"
                ) from exc
            if "error" in response:
                error = response["error"]
                message = error.get("message", str(error)) if isinstance(error, dict) else str(error)
                raise ProviderError(f"Provider {self.provider_id}: {message}")
            return response.get("result")
        finally:
            with self.pending_lock:
                self.pending.pop(request_id, None)

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def tools(self, refresh: bool = False) -> list[dict[str, Any]]:
        self.start()
        if self.tools_cache is None or refresh:
            result = _require_object(self.call("tools/list", {}, timeout=30), "tools/list result")
            tools = result.get("tools")
            if not isinstance(tools, list) or not all(isinstance(item, dict) for item in tools):
                raise ProviderError(f"Provider {self.provider_id} returned invalid tools")
            self.tools_cache = [item for item in tools if item.get("name") not in BLOCKED_TOOLS]
        return self.tools_cache

    def call_tool(self, name: str, arguments: dict[str, Any], timeout: int) -> dict[str, Any]:
        if name in BLOCKED_TOOLS:
            raise ProviderError(
                f"{name} is blocked in the structured provider; use AEC Codex developer fallback"
            )
        known = {item.get("name") for item in self.tools()}
        if name not in known:
            raise ProviderError(f"Provider {self.provider_id} does not expose {name}")
        result = self.call(
            "tools/call", {"name": name, "arguments": arguments}, timeout=timeout
        )
        return _require_object(result, "tools/call result")

    def close(self) -> None:
        process = self.process
        self.process = None
        self.tools_cache = None
        if not process:
            return
        try:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass
        finally:
            for stream in (process.stdin, process.stdout, process.stderr):
                try:
                    if stream:
                        stream.close()
                except Exception:
                    pass


class ProviderManager:
    def __init__(self):
        self.path = provider_config_path()
        self.config_mtime: float | None = None
        self.providers: dict[str, ChildMcpProcess] = {}
        self.warnings: list[str] = []
        atexit.register(self.close)

    def reload(self, force: bool = False) -> None:
        current_path = provider_config_path()
        if current_path != self.path:
            self.path = current_path
            force = True
        try:
            mtime = self.path.stat().st_mtime
        except OSError:
            mtime = None
        if not force and mtime == self.config_mtime:
            return
        self.close()
        self.config_mtime = mtime
        self.warnings = []
        if mtime is None:
            self.warnings.append(f"Provider config is not installed: {self.path}")
            return
        try:
            value = json.loads(self.path.read_text(encoding="utf-8-sig"))
            root = _require_object(value, "Provider config")
            descriptors = root.get("providers", [])
            if not isinstance(descriptors, list):
                raise ProviderError("providers must be an array")
            for descriptor_value in descriptors:
                descriptor = _require_object(descriptor_value, "Provider descriptor")
                provider_id = descriptor.get("id")
                if not isinstance(provider_id, str) or not re.fullmatch(r"[a-z0-9-]+", provider_id):
                    raise ProviderError("Provider id must be lower-case hyphen-case")
                if descriptor.get("enabled", True):
                    self.providers[provider_id] = ChildMcpProcess(descriptor)
        except (OSError, ValueError, ProviderError) as exc:
            self.warnings.append(str(exc))

    def list(self, probe: bool = False) -> dict[str, Any]:
        self.reload()
        values = []
        for provider_id, child in sorted(self.providers.items()):
            status = "configured"
            tool_count: int | None = None
            error: str | None = None
            if probe:
                try:
                    tool_count = len(child.tools())
                    status = "ready"
                except ProviderError as exc:
                    status = "unavailable"
                    error = str(exc)
            values.append(
                {
                    "id": provider_id,
                    "displayName": child.descriptor.get("displayName", provider_id),
                    "version": child.descriptor.get("version"),
                    "application": child.descriptor.get("application"),
                    "status": status,
                    "toolCount": tool_count,
                    "error": error,
                    "source": child.descriptor.get("source"),
                }
            )
        return {"providers": values, "warnings": self.warnings, "configPath": str(self.path)}

    def get(self, provider_id: str) -> ChildMcpProcess:
        self.reload()
        provider = self.providers.get(provider_id)
        if not provider:
            raise ProviderError(f"Provider is not configured or enabled: {provider_id}")
        return provider

    def search(self, query: str, provider_id: str | None, limit: int) -> dict[str, Any]:
        self.reload()
        words = [word for word in re.split(r"[^a-z0-9]+", query.lower()) if word]
        selected = (
            {provider_id: self.get(provider_id)}
            if provider_id
            else self.providers
        )
        matches: list[tuple[int, dict[str, Any]]] = []
        errors: list[str] = []
        for current_id, child in selected.items():
            try:
                for tool in child.tools():
                    name = str(tool.get("name", ""))
                    description = str(tool.get("description", ""))
                    haystack = (name + " " + description).lower()
                    score = sum(8 * name.lower().count(word) + haystack.count(word) for word in words)
                    if words and score == 0:
                        continue
                    access = classify_access(tool)
                    matches.append(
                        (
                            score,
                            {
                                "provider": current_id,
                                "name": name,
                                "description": description,
                                "access": access,
                                "blocked": name in BLOCKED_TOOLS,
                            },
                        )
                    )
            except ProviderError as exc:
                errors.append(str(exc))
        matches.sort(key=lambda item: (-item[0], item[1]["provider"], item[1]["name"]))
        return {"tools": [item[1] for item in matches[:limit]], "errors": errors}

    def schema(self, provider_id: str, tool_name: str) -> dict[str, Any]:
        for tool in self.get(provider_id).tools():
            if tool.get("name") == tool_name:
                return {"provider": provider_id, "tool": tool, "access": classify_access(tool)}
        raise ProviderError(f"Provider {provider_id} does not expose {tool_name}")

    def invoke(
        self,
        provider_id: str,
        tool_name: str,
        arguments: dict[str, Any],
        requested_access: str,
        dry_run: bool,
        timeout: int,
    ) -> dict[str, Any]:
        schema = self.schema(provider_id, tool_name)
        access = schema["access"]
        if requested_access == "read" and access != "read":
            raise ProviderError(
                f"{provider_id}.{tool_name} is not classified read-only; use the write provider tool"
            )
        values = dict(arguments)
        _validate_preview_arguments(schema["tool"], values)
        simulation = "none"
        if requested_access == "write" and dry_run:
            properties = (
                schema["tool"].get("inputSchema", {}).get("properties", {})
                if isinstance(schema["tool"].get("inputSchema"), dict)
                else {}
            )
            dry_key = next((key for key in ("dryRun", "dry_run") if key in properties), None)
            if not dry_key:
                # This preview is non-executing. It gives Codex a normalized
                # operation to show the user when the upstream MCP has no
                # native simulation contract.
                return {
                    "status": "previewed",
                    "provider": provider_id,
                    "providerVersion": self.get(provider_id).descriptor.get("version"),
                    "tool": tool_name,
                    "access": requested_access,
                    "dryRun": True,
                    "simulationLevel": "gateway",
                    "willExecute": False,
                    "arguments": values,
                    "note": "Upstream has no native dry-run; no provider call was made.",
                }
            values[dry_key] = True
            simulation = "provider"
        result = self.get(provider_id).call_tool(tool_name, values, timeout)
        return {
            "status": "failed" if result.get("isError") else "succeeded",
            "provider": provider_id,
            "providerVersion": self.get(provider_id).descriptor.get("version"),
            "tool": tool_name,
            "access": requested_access,
            "dryRun": dry_run,
            "simulationLevel": simulation,
            "result": result.get("structuredContent", result),
        }

    def close(self) -> None:
        for provider in self.providers.values():
            provider.close()
        self.providers = {}


def classify_access(tool: dict[str, Any]) -> str:
    annotations = tool.get("annotations")
    if isinstance(annotations, dict) and annotations.get("readOnlyHint") is True:
        return "read"
    if isinstance(annotations, dict) and annotations.get("readOnlyHint") is False:
        return "write"
    name = str(tool.get("name", "")).lower()
    if name in READ_TOOL_NAMES or name.startswith(READ_PREFIXES):
        return "read"
    return "write"


MANAGER = ProviderManager()
