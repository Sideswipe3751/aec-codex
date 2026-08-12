---
name: aec-codex
description: Set up, repair, upgrade, diagnose, control, and inspect local Autodesk Revit and AutoCAD sessions through AEC Codex. Use when the user asks to install or configure AEC Codex, check connector health, discover open Autodesk applications, inspect a project or drawing, query the current selection, read model or entity data, or create, update, or delete Revit elements and AutoCAD entities. Also use for version-aware routing, connector diagnostics, and transaction-safe Autodesk automation.
---

# AEC Codex

Use the AEC Codex MCP server as the only route into Revit or AutoCAD. Keep all
Autodesk API operations inside the target application's connector.

## Setup gate

Before the first Autodesk operation in a task, run the bundled
`scripts/Get-AecCodexHostStatus.ps1` script. It is read-only and returns JSON.
Resolve the script relative to this skill root; do not download a status
script or substitute remembered paths.

- Continue to the MCP workflow only when the status is `healthy`.
- For `not_installed`, `needs_prerequisite`, `needs_repair`,
  `needs_upgrade`, or `restart_required`, read [setup.md](references/setup.md)
  and follow that workflow.
- Do not install, repair, upgrade, or uninstall native components during the
  read-only check.
- Do not treat installing this Codex plugin as consent to modify Autodesk,
  AppData, the local MCP registration, or other local software.

## Workflow

1. Call `aec_list_providers` with `probe: true`. Use a ready structured
   provider before generating code.
2. Call `aec_search_provider_tools`, inspect the selected tool with
   `aec_get_provider_tool_schema`, then use `aec_call_provider_read` or
   `aec_call_provider_write` as classified.
3. For a write, call the write tool with `dryRun: true` first. A gateway
   preview does not execute; a provider preview delegates simulation to the
   upstream MCP. Execute with `dryRun: false` only when the request authorizes
   the change under the current Codex approval policy.
4. If no structured tool covers the operation, call `aec_list_instances`
   before using the AEC Codex connector fallback.
5. If more than one compatible instance is running, identify the target from
   the application, version, and document. Ask only when the user's intent does
   not determine a unique target.
6. Read current state before changing it. Prefer document, selection, query,
   and property tools over arbitrary code.
7. Use a write tool only when the user requested a change. Keep the operation
   inside one native transaction when atomic rollback is appropriate.
8. Read back the affected objects and report concrete identifiers and results.

## Tool selection

- Use `aec_get_document_info` for product, version, active document, units, and
  capabilities.
- Use `aec_get_selection` before making assumptions about the user's selection.
- Treat `mcp-servers-for-revit` and `U-C4N AutoCAD MCP` as the preferred
  structured providers. Discover their tools dynamically; do not assume a
  remembered tool name or schema.
- Use `aec_execute_read` only when no structured read tool covers the required
  Autodesk API surface.
- Use `aec_execute_write` only when no structured create/update tool covers the
  request. Treat it as potentially destructive because arbitrary code can
  delete or overwrite data.
- Never send Revit API code to AutoCAD or AutoCAD API code to Revit.
- Do not fall back to generated code merely because a structured call was
  denied, invalid, or failed during a mutation. Fallback is for missing
  capability, not a way around a provider safety boundary.

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

- Read [setup.md](references/setup.md) for installation, repair, upgrade,
  restart, health-check, and uninstall requests.
- Read [protocol.md](references/protocol.md) when diagnosing discovery, routing,
  authentication, request status, or connector compatibility.
- Read [tool-routing.md](references/tool-routing.md) before generating fallback
  Autodesk API code or combining several write operations.
- Read [providers.md](references/providers.md) for provider precedence,
  previews, blocked tools, version updates, and fallback rules.
