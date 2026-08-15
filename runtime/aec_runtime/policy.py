"""Agent-independent effect planning, policy, and request-bound grants."""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timezone
from typing import Any

from .capabilities import CapabilityDefinition, RoutePlan


class PolicyError(RuntimeError):
    """A request is invalid for policy evaluation."""


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def plan_effect(request: dict[str, Any], capability: CapabilityDefinition, route: RoutePlan) -> dict[str, Any]:
    target = request.get("target", {})
    arguments = request.get("arguments", {})
    summary = {
        "capabilityId": capability.capability_id,
        "providerId": route.selected.provider_id,
        "providerTrust": route.selected.trust,
        "intent": request.get("intent"),
        "risk": capability.risk,
        "dryRun": bool(request.get("dryRun", False)),
        "target": target,
        "argumentKeys": sorted(arguments) if isinstance(arguments, dict) else [],
    }
    return {**summary, "effectHash": canonical_hash(summary)}


class PolicyEngine:
    def __init__(self, sessions: Any | None = None, approvals: Any | None = None):
        # Imported lazily to keep canonical hashing independent and avoid a
        # module cycle while security.py uses canonical_hash.
        if sessions is None or approvals is None:
            from .security import ApprovalAuthority, SessionRegistry

            sessions = SessionRegistry() if sessions is None else sessions
            approvals = ApprovalAuthority() if approvals is None else approvals
        self.sessions = sessions
        self.approvals = approvals

    def evaluate(
        self,
        request: dict[str, Any],
        capability: CapabilityDefinition,
        route: RoutePlan,
        *,
        compatibility_v1: bool = False,
    ) -> dict[str, Any]:
        correlation_id = str(request.get("correlationId", ""))
        effect = plan_effect(request, capability, route)
        reasons: list[str] = []
        status = "allowed"
        session = request.get("adapterSession", {})
        if compatibility_v1:
            authenticated = isinstance(session, dict) and session.get("authenticated") is True
        else:
            authenticated = self.sessions.validate(session)
        if not authenticated:
            status, reasons = "denied", ["adapter_session_not_authenticated"]
        target = request.get("target", {})
        if (
            status == "allowed"
            and not compatibility_v1
            and request.get("intent") == "write"
            and route.selected.trust == "unknown"
        ):
            status, reasons = "denied", ["untrusted_provider_write_denied"]
        if status == "allowed" and request.get("intent") == "write":
            required = ("application", "release", "apiVariant", "instanceId", "processId", "document")
            if not compatibility_v1 and (not isinstance(target, dict) or any(
                target.get(key) is None or target.get(key) == "" for key in required
            )):
                status, reasons = "denied", ["write_target_not_exact"]
        if status == "allowed" and request.get("dryRun"):
            reasons.append("non_mutating_preview")
        elif status == "allowed" and capability.risk in {"high", "critical"}:
            if compatibility_v1:
                reasons.append("legacy_adapter_approval_authority")
            else:
                grant = request.get("approvalGrant")
                if not self.approvals.consume(grant, request, effect):
                    status, reasons = "approval_required", ["request_bound_approval_required"]
        if not reasons:
            reasons.append("policy_requirements_satisfied")
        return {
            "kind": "policy_decision",
            "contractVersion": 2,
            "decisionId": "decision-" + uuid.uuid4().hex,
            "correlationId": correlation_id,
            "status": status,
            "reasonCodes": reasons,
            "effectHash": effect["effectHash"],
            "evaluatedAtUtc": utc_now(),
            "effect": effect,
        }

def approval_challenge(request: dict[str, Any], decision: dict[str, Any]) -> dict[str, Any]:
    request_without_grant = {key: value for key, value in request.items() if key != "approvalGrant"}
    return {
        "requestHash": canonical_hash(request_without_grant),
        "targetHash": canonical_hash(request.get("target", {})),
        "effectHash": decision["effectHash"],
        "correlationId": request.get("correlationId"),
        "effect": decision.get("effect"),
    }
