from __future__ import annotations

import sys
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "runtime"))

from aec_runtime import (  # noqa: E402
    AuditTrail,
    BimBridgeRuntime,
    CapabilityError,
    PolicyEngine,
    ProviderCandidate,
    ExecutionJournal,
    approval_challenge,
    normalize_execution_result,
)


def request(intent: str = "write") -> dict[str, object]:
    return {
        "kind": "execution_request",
        "contractVersion": 2,
        "correlationId": "correlation-1234567890",
        "adapterSession": {
            "adapterId": "contract-test",
            "sessionId": "session-123",
            "authenticated": True,
        },
        "target": {
            "application": "revit",
            "release": "2027",
            "apiVariant": "27.2.0.39",
            "instanceId": "revit-2027-1234",
            "processId": 1234,
            "document": {"id": "path:c:/test.rvt", "title": "test.rvt"},
        },
        "capabilityId": f"revit.code.{intent}",
        "arguments": {"description": "test", "code": "return 7;"},
        "intent": intent,
        "timeoutSeconds": 30,
        "dryRun": False,
    }


def authenticated_request(runtime: BimBridgeRuntime, intent: str = "write") -> dict[str, object]:
    value = request(intent)
    value["adapterSession"] = runtime.open_adapter_session("contract-test")
    return value


class RuntimeCoreTests(unittest.TestCase):
    def test_revit_view_capture_is_a_typed_low_risk_host_capability(self) -> None:
        runtime = BimBridgeRuntime()
        capability = runtime.capabilities.get("revit.view.capture")
        self.assertEqual("low", capability.risk)
        self.assertEqual(("read",), capability.intents)
        self.assertEqual(("view.capture",), capability.required_host_capabilities)
        self.assertEqual(4096, capability.input_schema["properties"]["pixelSize"]["maximum"])

    def test_routing_is_deterministic_and_cannot_fallback_after_start(self) -> None:
        runtime = BimBridgeRuntime()
        candidates = (
            ProviderCandidate("z-provider", "host", "document", "local", priority=10),
            ProviderCandidate("a-provider", "host", "document", "local", priority=10),
        )
        plan, decision = runtime.prepare(authenticated_request(runtime, "read"), candidates=candidates)
        self.assertEqual("a-provider", plan.selected.provider_id)
        self.assertEqual("approval_required", decision["status"])
        plan.mark_execution_started()
        with self.assertRaisesRegex(CapabilityError, "fallback is forbidden"):
            plan.fallback()

    def test_v2_write_requires_an_exact_document_target(self) -> None:
        runtime = BimBridgeRuntime()
        value = authenticated_request(runtime)
        del value["target"]["document"]  # type: ignore[index]
        with self.assertRaisesRegex(CapabilityError, "exact target"):
            runtime.prepare(value)

    def test_unknown_provider_cannot_execute_a_v2_write(self) -> None:
        runtime = BimBridgeRuntime()
        candidates = (
            ProviderCandidate("unknown-provider", "structured_mcp", "document", "unknown"),
        )
        _plan, decision = runtime.prepare(authenticated_request(runtime), candidates=candidates)
        self.assertEqual("denied", decision["status"])
        self.assertEqual(["untrusted_provider_write_denied"], decision["reasonCodes"])

    def test_critical_write_requires_bound_approval_and_rejects_replay(self) -> None:
        policy = PolicyEngine()
        runtime = BimBridgeRuntime(policy=policy)
        value = authenticated_request(runtime)
        plan, decision = runtime.prepare(value)
        self.assertEqual("approval_required", decision["status"])
        challenge = approval_challenge(value, decision)
        self.assertEqual(decision["effectHash"], challenge["effectHash"])
        value["approvalGrant"] = runtime.issue_approval(
            value, decision, issued_by="contract-test-approval-ui"
        )
        _plan, allowed = runtime.prepare(value)
        self.assertEqual("allowed", allowed["status"])
        _plan, replay = runtime.prepare(value)
        self.assertEqual("approval_required", replay["status"])

    def test_self_asserted_session_and_forged_grant_are_rejected(self) -> None:
        runtime = BimBridgeRuntime()
        value = request()
        _plan, denied = runtime.prepare(value)
        self.assertEqual("denied", denied["status"])

        value = authenticated_request(runtime)
        _plan, challenge = runtime.prepare(value)
        grant = runtime.issue_approval(value, challenge, issued_by="contract-test-approval-ui")
        grant["signature"] = "0" * 64
        value["approvalGrant"] = grant
        _plan, forged = runtime.prepare(value)
        self.assertEqual("approval_required", forged["status"])

    def test_audit_redacts_dynamic_code_and_tokens(self) -> None:
        audit = AuditTrail()
        audit.record("correlation-1", "request", {"code": "secret", "token": "secret", "safe": 7})
        details = audit.records()[0]["details"]
        self.assertEqual("[redacted]", details["code"])
        self.assertEqual("[redacted]", details["token"])
        self.assertEqual(7, details["safe"])

    def test_execution_journal_is_redacted_and_hash_chained(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = ExecutionJournal(Path(temporary))
            audit = AuditTrail(sink=journal.write)
            audit.record("correlation-1", "request", {"sessionToken": "secret", "safe": 1})
            audit.record("correlation-1", "result", {"safe": 2})
            path = next(Path(temporary).glob("*.jsonl"))
            values = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
            self.assertEqual("[redacted]", values[0]["details"]["sessionToken"])
            self.assertEqual(values[0]["recordHash"], values[1]["previousHash"])

    def test_execution_normalization_preserves_rollback_evidence(self) -> None:
        runtime = BimBridgeRuntime()
        value = authenticated_request(runtime)
        result = normalize_execution_result(
            value,
            provider_id="revit.connector.v1",
            host_evidence=value["target"],  # type: ignore[arg-type]
            provider_result={"status": "failed", "rolledBack": True, "changes": {"created": ["42"]}},
            audit_id="audit-1234567890123456",
        )
        self.assertEqual("failed", result["status"])
        self.assertEqual("rolled_back", result["transaction"]["status"])
        self.assertTrue(result["transaction"]["rolledBack"])
        self.assertEqual(["42"], result["changes"]["created"])

    def test_v2_execute_uses_one_runtime_pipeline(self) -> None:
        runtime = BimBridgeRuntime()
        value = authenticated_request(runtime, "read")
        value["capabilityId"] = "revit.document.info"
        value["arguments"] = {}
        instance = {
            "protocolVersion": 1,
            "instanceId": "revit-2027-1234",
            "application": "revit",
            "applicationVersion": "2027",
            "processId": 1234,
            "url": "http://127.0.0.1:4821",
            "token": "t" * 32,
            "startedAtUtc": "2026-08-14T00:00:00Z",
            "document": {"id": "path:c:/test.rvt", "title": "test.rvt"},
            "capabilities": ["document.info", "code.read", "code.write"],
        }
        with patch("aec_runtime.service.select_exact_target", return_value=instance), patch(
            "aec_runtime.service.connector_request", return_value={"application": "revit", "status": "ready"}
        ):
            result = runtime.execute(value)
        self.assertEqual("succeeded", result["status"])
        self.assertEqual("revit.connector.v1", result["selected"]["providerId"])
        self.assertEqual("not_requested", result["verification"]["status"])
        schema = json.loads(
            (REPOSITORY_ROOT / "protocol" / "v2" / "aec-contract.schema.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertTrue(set(result).issubset(schema["$defs"]["executionResult"]["properties"]))

    def test_v2_write_executes_only_with_signed_grant(self) -> None:
        runtime = BimBridgeRuntime()
        value = authenticated_request(runtime)
        _plan, challenge = runtime.prepare(value, host_capabilities=["code.write"])
        value["approvalGrant"] = runtime.issue_approval(
            value, challenge, issued_by="contract-test-approval-ui"
        )
        instance = {
            "protocolVersion": 1,
            "instanceId": "revit-2027-1234",
            "application": "revit",
            "applicationVersion": "2027",
            "processId": 1234,
            "url": "http://127.0.0.1:4821",
            "token": "t" * 32,
            "startedAtUtc": "2026-08-14T00:00:00Z",
            "document": {"id": "path:c:/test.rvt", "title": "test.rvt"},
            "capabilities": ["code.write"],
        }
        with patch("aec_runtime.service.select_exact_target", return_value=instance), patch(
            "aec_runtime.service.execute_connector_request",
            return_value={"status": "succeeded", "rolledBack": False, "result": {"value": 7}},
        ):
            result = runtime.execute(value)
        self.assertEqual("succeeded", result["status"])
        self.assertEqual("committed", result["transaction"]["status"])


if __name__ == "__main__":
    unittest.main()
