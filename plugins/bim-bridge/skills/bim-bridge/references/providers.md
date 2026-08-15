# Structured providers

## Precedence

Use `revit-community` (`mcp-servers-for-revit`) for Revit and `autocad-pro`
(`U-C4N/Autocad-MCP`) for AutoCAD. The provider gateway starts each upstream
MCP as an isolated STDIO child process and discovers its current tools and
schemas at runtime. Search, inspect the schema, and then call; do not encode a
static copy of an upstream catalog in prompts or fallback code.

Use the BIM Bridge dynamic C# connector only if provider discovery proves that
the required capability is absent or the installed upstream version does not
support the running Autodesk version. A permission denial, validation error,
transaction failure, or destructive-tool refusal is not a missing capability.

## Reads and writes

`aec_call_provider_read` refuses any tool not classified read-only.
`aec_call_provider_write` is always write-annotated and requires an explicit
`dryRun` boolean. If the upstream schema declares `dryRun` or `dry_run`, the
preview is delegated to it. Otherwise the gateway returns a normalized,
non-executing preview and does not call the provider. Reissue with
`dryRun: false` to perform the operation under Codex's current approval policy.

The gateway blocks upstream arbitrary-code or command tools, including
`send_code_to_revit`, `system_run_command`, and LISP execution. When arbitrary
code is genuinely required, use the BIM Bridge host capability because it supplies
target routing, authentication, audit records, native transaction ownership,
and rollback.

## Updates and failure behavior

Provider versions, source commits, download URLs, and SHA-256 values are pinned
in `providers.lock.json`. An update is eligible only after its source/security
patch builds, both MCPs initialize, their schemas are snapshotted and diffed,
and smoke tests pass. Child MCP server changes activate in a new Codex task.
Revit add-in DLL changes additionally require a Revit restart. A previous
active provider configuration is retained for rollback.

If a provider is unavailable, report its exact diagnostic from
`aec_list_providers(probe: true)`. It is safe to use the connector fallback for
an otherwise-supported operation only after confirming the failure is a
provider availability/version issue and not a rejected write.
