"""Runtime-owned adapter sessions and signed approval grants."""

from __future__ import annotations

import hashlib
import hmac
import secrets
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from .policy import canonical_hash, utc_now


class SessionError(RuntimeError):
    """An adapter session or approval grant is not trusted by this runtime."""


def _parse_utc(value: Any) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


@dataclass(frozen=True)
class _SessionRecord:
    adapter_id: str
    token_hash: str
    expires_at: datetime


class SessionRegistry:
    """Maintains process-local authenticated sessions for trusted transports."""

    def __init__(self, ttl_seconds: int = 8 * 60 * 60):
        self.ttl_seconds = max(60, int(ttl_seconds))
        self._sessions: dict[str, _SessionRecord] = {}
        self._lock = threading.Lock()

    def open(self, adapter_id: str, *, ttl_seconds: int | None = None) -> dict[str, Any]:
        if not isinstance(adapter_id, str) or not adapter_id.strip():
            raise SessionError("adapter_id is required")
        session_id = "session-" + uuid.uuid4().hex
        token = secrets.token_urlsafe(32)
        lifetime = self.ttl_seconds if ttl_seconds is None else max(60, int(ttl_seconds))
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=lifetime)
        with self._lock:
            self._sessions[session_id] = _SessionRecord(
                adapter_id=adapter_id.strip(),
                token_hash=hashlib.sha256(token.encode("utf-8")).hexdigest(),
                expires_at=expires_at,
            )
        return {
            "adapterId": adapter_id.strip(),
            "sessionId": session_id,
            "authenticated": True,
            "sessionToken": token,
            "expiresAtUtc": expires_at.isoformat().replace("+00:00", "Z"),
        }

    def validate(self, value: Any) -> bool:
        if not isinstance(value, dict):
            return False
        if value.get("authenticated") is not True:
            return False
        session_id = value.get("sessionId")
        adapter_id = value.get("adapterId")
        token = value.get("sessionToken")
        if not all(isinstance(item, str) and item for item in (session_id, adapter_id, token)):
            return False
        with self._lock:
            record = self._sessions.get(session_id)
            if record and record.expires_at <= datetime.now(timezone.utc):
                self._sessions.pop(session_id, None)
                record = None
        if not record or record.adapter_id != adapter_id:
            return False
        declared_expiry = _parse_utc(value.get("expiresAtUtc"))
        if declared_expiry is None or declared_expiry != record.expires_at:
            return False
        supplied = hashlib.sha256(token.encode("utf-8")).hexdigest()
        return hmac.compare_digest(record.token_hash, supplied)

    def close(self, session_id: str) -> None:
        with self._lock:
            self._sessions.pop(session_id, None)


class ApprovalAuthority:
    """Issues and verifies short-lived grants authenticated by an HMAC signature.

    The authority is called only by a trusted approval presenter or broker. Agent
    adapters receive grants but do not receive the signing key.
    """

    def __init__(self, secret: bytes | None = None):
        self._secret = secrets.token_bytes(32) if secret is None else bytes(secret)
        if len(self._secret) < 32:
            raise ValueError("Approval signing secret must be at least 32 bytes")
        self._consumed_nonces: set[str] = set()
        self._lock = threading.Lock()

    def issue(
        self,
        request: dict[str, Any],
        decision: dict[str, Any],
        *,
        issued_by: str,
        ttl_seconds: int = 300,
    ) -> dict[str, Any]:
        if decision.get("status") != "approval_required":
            raise SessionError("Approval grants may be issued only for an approval challenge")
        if decision.get("correlationId") != request.get("correlationId"):
            raise SessionError("Approval challenge does not match the request correlation")
        if not isinstance(decision.get("effectHash"), str) or len(decision["effectHash"]) != 64:
            raise SessionError("Approval challenge has no valid effect hash")
        if not isinstance(issued_by, str) or not issued_by.strip():
            raise SessionError("issued_by is required")
        request_without_grant = {
            key: value for key, value in request.items() if key != "approvalGrant"
        }
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=max(30, int(ttl_seconds)))
        grant: dict[str, Any] = {
            "kind": "approval_grant",
            "contractVersion": 2,
            "grantId": "grant-" + uuid.uuid4().hex,
            "requestHash": canonical_hash(request_without_grant),
            "targetHash": canonical_hash(request.get("target", {})),
            "effectHash": str(decision.get("effectHash", "")),
            "expiresAtUtc": expires_at.isoformat().replace("+00:00", "Z"),
            "nonce": secrets.token_urlsafe(24),
            "issuedBy": issued_by.strip(),
            "issuedAtUtc": utc_now(),
        }
        grant["signature"] = self._signature(grant)
        return grant

    def consume(self, grant: Any, request: dict[str, Any], effect: dict[str, Any]) -> bool:
        if not isinstance(grant, dict):
            return False
        required_strings = (
            "grantId",
            "requestHash",
            "targetHash",
            "effectHash",
            "expiresAtUtc",
            "nonce",
            "issuedBy",
            "issuedAtUtc",
            "signature",
        )
        if (
            grant.get("kind") != "approval_grant"
            or grant.get("contractVersion") != 2
            or any(not isinstance(grant.get(key), str) or not grant[key] for key in required_strings)
        ):
            return False
        signature = str(grant["signature"])
        if not hmac.compare_digest(signature, self._signature(grant)):
            return False
        request_without_grant = {
            key: value for key, value in request.items() if key != "approvalGrant"
        }
        if grant["requestHash"] != canonical_hash(request_without_grant):
            return False
        if grant["targetHash"] != canonical_hash(request.get("target", {})):
            return False
        if grant["effectHash"] != effect.get("effectHash"):
            return False
        expiry = _parse_utc(grant["expiresAtUtc"])
        issued_at = _parse_utc(grant["issuedAtUtc"])
        now = datetime.now(timezone.utc)
        if expiry is None or issued_at is None or expiry <= now or issued_at > now + timedelta(minutes=1):
            return False
        nonce = str(grant["nonce"])
        with self._lock:
            if nonce in self._consumed_nonces:
                return False
            self._consumed_nonces.add(nonce)
        return True

    def _signature(self, grant: dict[str, Any]) -> str:
        unsigned = {key: value for key, value in grant.items() if key != "signature"}
        payload = canonical_hash(unsigned).encode("ascii")
        return hmac.new(self._secret, payload, hashlib.sha256).hexdigest()
