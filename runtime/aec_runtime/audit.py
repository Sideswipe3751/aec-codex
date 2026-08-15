"""Bounded, correlation-aware audit records for BIM Bridge Runtime."""

from __future__ import annotations

import hashlib
import json
import os
import threading
import uuid
from copy import deepcopy
from datetime import datetime, timezone
from typing import Any, Callable
from pathlib import Path


SENSITIVE_KEYS = {
    "token",
    "sessionToken",
    "authorization",
    "code",
    "approvalGrant",
    "nonce",
    "signature",
}


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: "[redacted]" if key.lower() in {item.lower() for item in SENSITIVE_KEYS} else _redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_redact(item) for item in value]
    return value


def journal_directory(environment: dict[str, str] | None = None) -> Path:
    values = os.environ if environment is None else environment
    configured = values.get("BIM_BRIDGE_JOURNAL_DIR")
    if configured:
        return Path(configured)
    local = values.get("LOCALAPPDATA", str(Path.home()))
    return Path(local) / "BIM Bridge" / "journal"


class ExecutionJournal:
    """Append-only, hash-chained JSONL execution evidence."""

    def __init__(self, directory: Path | None = None):
        self.directory = journal_directory() if directory is None else Path(directory)
        self._previous: dict[Path, str] = {}
        self._lock = threading.Lock()

    def write(self, record: dict[str, Any]) -> None:
        day = str(record.get("recordedAtUtc", "unknown"))[:10]
        path = self.directory / f"{day}.jsonl"
        with self._lock:
            self.directory.mkdir(parents=True, exist_ok=True)
            previous = self._previous.get(path)
            if previous is None:
                previous = self._read_last_hash(path)
            entry = deepcopy(record)
            entry["previousHash"] = previous
            encoded = json.dumps(entry, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
            entry["recordHash"] = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
            with path.open("a", encoding="utf-8", newline="\n") as stream:
                stream.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")
            self._previous[path] = entry["recordHash"]

    @staticmethod
    def _read_last_hash(path: Path) -> str:
        if not path.is_file():
            return "0" * 64
        try:
            with path.open("rb") as stream:
                stream.seek(0, os.SEEK_END)
                size = stream.tell()
                stream.seek(max(0, size - 65536), os.SEEK_SET)
                lines = stream.read().decode("utf-8", errors="replace").splitlines()
            if lines:
                value = json.loads(lines[-1])
                record_hash = value.get("recordHash") if isinstance(value, dict) else None
                if isinstance(record_hash, str) and len(record_hash) == 64:
                    return record_hash
        except (OSError, ValueError, json.JSONDecodeError):
            pass
        return "0" * 64


class AuditTrail:
    def __init__(self, limit: int = 1000, sink: Callable[[dict[str, Any]], None] | None = None):
        self.limit = max(1, limit)
        self.sink = sink
        self._records: list[dict[str, Any]] = []
        self._lock = threading.Lock()

    def record(self, correlation_id: str, event: str, details: dict[str, Any]) -> str:
        audit_id = "audit-" + uuid.uuid4().hex
        record = {
            "auditId": audit_id,
            "correlationId": correlation_id,
            "event": event,
            "recordedAtUtc": _utc_now(),
            "details": _redact(deepcopy(details)),
        }
        with self._lock:
            self._records.append(record)
            del self._records[:-self.limit]
        if self.sink:
            self.sink(deepcopy(record))
        return audit_id

    def records(self, correlation_id: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            values = deepcopy(self._records)
        return [item for item in values if correlation_id in {None, item["correlationId"]}]
