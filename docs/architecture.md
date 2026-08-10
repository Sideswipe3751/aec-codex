# Architecture

## Boundaries

AEC Codex has three trust boundaries:

1. Codex loads the plugin skill and starts the local STDIO MCP host.
2. The MCP host discovers active Autodesk connectors from per-process instance
   descriptors under `%APPDATA%\AEC Codex\instances`.
3. A connector accepts authenticated loopback HTTP requests and dispatches all
   Autodesk API access onto the application's supported execution context.

The MCP host never loads Autodesk assemblies. Revit and AutoCAD connectors do
not call OpenAI services and do not expose a non-loopback listener.

## Version model

The protocol and MCP host are version-independent. Autodesk adapters are built
for three runtime families:

- `net48`: Autodesk 2024 and selected earlier releases.
- `net8.0-windows`: Autodesk 2025 and 2026 compatibility line.
- `net10.0-windows`: Autodesk 2027.

V1.0 certifies 2024 and 2027 only. Supporting a version means more than a
successful build: loading, document routing, transactions, rollback, shutdown,
and representative read/write operations must pass inside that exact product.

## Approval model

Codex is the sole user-facing approval authority. Connectors do not implement
an Ask Approval/Full Access setting and do not display write-confirmation
dialogs. MCP tools advertise read-only, side-effect, and destructive semantics
so Codex can apply the user's selected action-approval policy.

Authentication, validation, transaction rollback, timeouts, and audit logging
remain mandatory engineering controls. They do not constitute a second
approval layer.
