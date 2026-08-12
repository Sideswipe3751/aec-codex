# Architecture

## Boundaries

AEC Codex has three trust boundaries:

1. Codex loads the plugin skill and starts the local STDIO MCP host.
2. The MCP host discovers active Autodesk connectors from per-process instance
   descriptors under `%APPDATA%\AEC Codex\instances`.
3. A connector accepts authenticated loopback HTTP requests and dispatches all
   Autodesk API access onto the application's supported execution context.

The MCP host also manages two version-pinned structured child MCPs over STDIO.
Their tools are discovered at runtime and exposed through a five-tool gateway,
so upstream catalogs can evolve without increasing Codex's top-level tool
surface. Revit's community add-in is patched to loopback-only transport with a
per-user token; AutoCAD MCP runs in live COM mode with remote HTTP and arbitrary
command/LISP execution disabled.

The MCP host never loads Autodesk assemblies. Revit and AutoCAD connectors do
not call OpenAI services and do not expose a non-loopback listener.

## Version model

The protocol and MCP host are version-independent. The bridge is designed for
three Autodesk runtime families:

- `net48`: Autodesk 2024 and selected earlier releases.
- `net8.0-windows`: Autodesk 2025 and 2026 compatibility line.
- `net10.0-windows`: Autodesk 2027.

The current adapter projects and installer target 2024. The shared bridge also
builds on .NET 10 so 2027 adapters can reuse it, but 2027 is not certified or
shipped yet. Supporting a version means more than a successful build: loading,
document routing, transactions, rollback, shutdown, and representative
read/write operations must pass inside that exact product.

## Approval model

Codex is the sole user-facing approval authority. Connectors do not implement
an Ask Approval/Full Access setting and do not display write-confirmation
dialogs. MCP tools advertise read-only, side-effect, and destructive semantics
so Codex can apply the user's selected action-approval policy.

Authentication, validation, transaction rollback, timeouts, and audit logging
remain mandatory engineering controls. They do not constitute a second
approval layer.

## Dynamic execution and rollback

The MCP exposes separate read and write tools. Their `code` value is a C#
method body compiled in memory inside the selected Autodesk process. Revit
dispatches it through `ExternalEvent`; AutoCAD dispatches it from the idle
application context. The code has access only to the variables documented by
the connector contract, although it runs with the Autodesk process/user's OS
permissions and must therefore remain a write-annotated capability.

Revit wraps each write in a `TransactionGroup` and `Transaction`. AutoCAD wraps
each write in a `DocumentLock` and database `Transaction`. Generated code does
not own these objects. An exception aborts the entire request and the response
sets `rolledBack: true`; a successful response is emitted only after commit.

## Installer transaction

The current-user installer has two explicit modes. `HostOnly` installs native
connectors, structured providers, the local MCP host, a maintenance copy of the
uninstaller, and versioned state without modifying any Codex marketplace.
`Development` additionally installs and registers a cache-busted personal
plugin from a full source checkout.

Both modes move every existing target into a private rollback directory and
delete it only after connector and provider installation succeeds. Installation
is refused while Revit or AutoCAD is running. Marketplace first-run setup uses
a pinned host-only release URL and SHA-256 digest. The host payload excludes the
manifest that pins its hash, avoiding a self-referential archive.
