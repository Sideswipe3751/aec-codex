---
name: aec-codex
description: Control and inspect local Autodesk Revit and AutoCAD sessions through the AEC Codex MCP tools. Use when the user asks Codex to discover open Autodesk applications, inspect a project or drawing, query the current selection, read model or entity data, or create, update, or delete Revit elements and AutoCAD entities. Also use for version-aware routing, connector diagnostics, and transaction-safe Autodesk automation.
---

# AEC Codex

Use the AEC Codex MCP server as the only route into Revit or AutoCAD. Keep all
Autodesk API operations inside the target application's connector.

## Workflow

1. Call `aec_list_instances` before the first Autodesk operation in a task.
2. If more than one compatible instance is running, identify the target from
   the application, version, and document. Ask only when the user's intent does
   not determine a unique target.
3. Read current state before changing it. Prefer document, selection, query,
   and property tools over arbitrary code.
4. Use a write tool only when the user requested a change. Keep the operation
   inside one native transaction when atomic rollback is appropriate.
5. Read back the affected objects and report concrete identifiers and results.

## Tool selection

- Use `aec_get_document_info` for product, version, active document, units, and
  capabilities.
- Use `aec_get_selection` before making assumptions about the user's selection.
- Use `aec_execute_read` only when no structured read tool covers the required
  Autodesk API surface.
- Use `aec_execute_write` only when no structured create/update tool covers the
  request. Treat it as potentially destructive because arbitrary code can
  delete or overwrite data.
- Never send Revit API code to AutoCAD or AutoCAD API code to Revit.

## Approval and safety

- Let Codex apply the user's action-approval policy. Do not ask for or simulate
  a second approval inside Revit or AutoCAD.
- Do not bypass a tool's destructive annotation or disguise a write as a read.
- Use explicit object identifiers and bounded queries. Avoid document-wide
  writes unless the request clearly requires them.
- Verify that a disposable document is active before development smoke tests.
- Stop when the connector reports a version, document, transaction, or API
  context mismatch; do not retry a write against another instance implicitly.

## References

- Read [protocol.md](references/protocol.md) when diagnosing discovery, routing,
  authentication, request status, or connector compatibility.
- Read [tool-routing.md](references/tool-routing.md) before generating fallback
  Autodesk API code or combining several write operations.
