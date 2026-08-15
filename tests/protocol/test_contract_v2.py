from __future__ import annotations

import copy
import json
import re
import unittest
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PROTOCOL_ROOT = REPOSITORY_ROOT / "protocol" / "v2"
APPLICATIONS = {"revit", "autocad"}
RESULT_STATUSES = {
    "succeeded",
    "succeeded_unverified",
    "partial",
    "failed",
    "rejected",
    "expired",
    "cancelled",
}


class ContractError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def require(condition: bool, code: str, message: str) -> None:
    if not condition:
        raise ContractError(code, message)


def validate_target(target: Any, exact: bool) -> None:
    require(isinstance(target, dict), "target", "target must be an object")
    require(target.get("application") in APPLICATIONS, "target_application", "unsupported application")
    require(bool(re.fullmatch(r"[0-9]{4}", str(target.get("release", "")))), "target_release", "invalid release")
    require(bool(target.get("apiVariant")), "target_api_variant", "apiVariant is required")
    if exact:
        require(
            bool(target.get("instanceId")) and isinstance(target.get("processId"), int) and bool(target.get("document")),
            "exact_write_target",
            "writes require exact instance, process, and document identity",
        )


def validate_request(value: Any) -> None:
    require(isinstance(value, dict), "request", "request must be an object")
    require(value.get("kind") == "execution_request", "kind", "unexpected request kind")
    require(value.get("contractVersion") == 2, "contract_version", "contractVersion must be 2")
    session = value.get("adapterSession")
    require(
        isinstance(session, dict)
        and session.get("authenticated") is True
        and isinstance(session.get("sessionToken"), str)
        and len(session["sessionToken"]) >= 32,
        "adapter_authentication",
        "adapter session is not authenticated",
    )
    intent = value.get("intent")
    require(intent in {"read", "write"}, "intent", "intent must be read or write")
    validate_target(value.get("target"), exact=intent == "write")
    capability_id = value.get("capabilityId")
    require(isinstance(capability_id, str) and capability_id.startswith(value["target"]["application"] + "."), "capability_target", "capability does not match target application")
    if capability_id.endswith(".write"):
        require(intent == "write", "capability_intent", "write capability requires write intent")
    if capability_id.endswith(".read"):
        require(intent == "read", "capability_intent", "read capability requires read intent")
    timeout = value.get("timeoutSeconds")
    require(isinstance(timeout, int) and not isinstance(timeout, bool) and 1 <= timeout <= 1800, "timeout_range", "timeout is outside the contract range")
    require(isinstance(value.get("arguments"), dict), "arguments", "arguments must be an object")
    require(isinstance(value.get("dryRun"), bool), "dry_run", "dryRun must be boolean")


def validate_result(value: Any) -> None:
    require(isinstance(value, dict), "result", "result must be an object")
    require(value.get("kind") == "execution_result", "kind", "unexpected result kind")
    require(value.get("contractVersion") == 2, "contract_version", "contractVersion must be 2")
    require(value.get("status") in RESULT_STATUSES, "result_status", "invalid normalized status")
    validate_target(value.get("hostEvidence"), exact=True)
    transaction = value.get("transaction")
    require(isinstance(transaction, dict) and isinstance(transaction.get("rolledBack"), bool), "transaction", "transaction evidence is incomplete")
    if transaction.get("status") == "rolled_back":
        require(transaction["rolledBack"] is True, "transaction_consistency", "rolled_back status requires rolledBack=true")
    if transaction.get("status") == "committed":
        require(transaction["rolledBack"] is False, "transaction_consistency", "committed status requires rolledBack=false")
    changes = value.get("changes")
    require(isinstance(changes, dict), "changes", "change evidence is required")
    for key in ("created", "modified", "deleted"):
        require(isinstance(changes.get(key), list), "changes", f"changes.{key} must be an array")
    verification = value.get("verification")
    require(isinstance(verification, dict) and verification.get("status") in {"not_requested", "passed", "failed", "inconclusive"}, "verification", "verification evidence is invalid")


class ContractV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = json.loads((PROTOCOL_ROOT / "aec-contract.schema.json").read_text(encoding="utf-8"))
        cls.read_request = json.loads((PROTOCOL_ROOT / "examples" / "read-request.json").read_text(encoding="utf-8"))
        cls.write_result = json.loads((PROTOCOL_ROOT / "examples" / "write-result.json").read_text(encoding="utf-8"))
        cls.negative_requests = json.loads((PROTOCOL_ROOT / "examples" / "negative-requests.json").read_text(encoding="utf-8"))

    def test_schema_exposes_every_phase_one_domain_type(self) -> None:
        definitions = self.schema["$defs"]
        expected = {
            "target",
            "capability",
            "executionRequest",
            "executionResult",
            "structuredError",
            "verificationSpec",
            "verificationResult",
            "policyDecision",
            "approvalGrant",
            "effectSummary",
        }
        self.assertTrue(expected.issubset(definitions))
        self.assertEqual(2, definitions["executionRequest"]["properties"]["contractVersion"]["const"])
        self.assertEqual(RESULT_STATUSES, set(definitions["executionResult"]["properties"]["status"]["enum"]))
        self.assertIn("effect", definitions["policyDecision"]["properties"])
        self.assertIn("signature", definitions["approvalGrant"]["properties"])

    def test_golden_request_and_result(self) -> None:
        validate_request(self.read_request)
        validate_result(self.write_result)

    def test_negative_request_fixtures(self) -> None:
        for fixture in self.negative_requests:
            with self.subTest(fixture=fixture["name"]):
                candidate = copy.deepcopy(self.read_request)
                patch = fixture["patch"]
                for field in patch.get("removeTargetFields", []):
                    candidate["target"].pop(field, None)
                if "authenticated" in patch:
                    candidate["adapterSession"]["authenticated"] = patch["authenticated"]
                for field in ("contractVersion", "intent", "capabilityId", "timeoutSeconds"):
                    if field in patch:
                        candidate[field] = patch[field]
                with self.assertRaises(ContractError) as raised:
                    validate_request(candidate)
                self.assertEqual(fixture["error"], raised.exception.code)


if __name__ == "__main__":
    unittest.main()
