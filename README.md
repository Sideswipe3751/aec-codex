# AEC Codex

AEC Codex is a local Codex plugin that connects Codex to Autodesk Revit and
AutoCAD. The project uses one MCP protocol and shared connector core with
version-specific Autodesk adapters.

## V1.0 goal

AEC Codex V1.0 provides a complete local experience: one-command current-user
installation, live document and selection reads, dynamic Autodesk API queries,
element/entity creation and modification, and atomic rollback for failed write
requests. Codex remains the only user-facing approval layer.

## V1.0 support targets

| Product | Version | Runtime | Release gate |
| --- | --- | --- | --- |
| Revit | 2024 | .NET Framework 4.8 | Live tested |
| Revit | 2027 | .NET 10 | Live tested before V1.0 |
| AutoCAD | 2024 | .NET Framework 4.8 | Live tested |
| AutoCAD | 2027 | .NET 10 | Live tested before V1.0 |

The source layout reserves a .NET 8 compatibility line for Autodesk 2025 and
2026, but those versions are not certified until they pass live tests.

## Repository layout

- `plugins/aec-codex`: Codex plugin, AEC skill, and dependency-free MCP host.
- `protocol`: versioned connector discovery and request contracts.
- `src`: shared bridge and Autodesk connector projects.
- `tests`: protocol, MCP, bridge, and live smoke tests.
- `docs`: architecture, security, compatibility, and development notes.

The existing Zexus Revit bridge remains a separate reference implementation.
Its loopback transport, bearer-token authentication, audit log, request queue,
and Revit `ExternalEvent` approach are being reused. Its Autodesk-side approval
dialog is intentionally not carried forward: Codex is the only user-facing
approval layer.

## Install the development build

Close Revit and AutoCAD, then run from PowerShell:

```powershell
& .\installer\Install-AecCodex.ps1
```

The installer builds the solution, installs Revit 2024 and AutoCAD 2024
connectors for the current Windows user, registers the personal Codex plugin,
and rolls every changed path back if registration fails. Restart Codex and the
Autodesk applications after installation. Use `-Action Repair` to reinstall or
`-Action Uninstall` to remove it.

The public bootstrap downloads a release ZIP and verifies its SHA-256 before
running the packaged installer; it never pipes an unverified remote script into
`Invoke-Expression`.
