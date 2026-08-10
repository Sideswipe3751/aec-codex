# AEC Codex

AEC Codex is a local Codex plugin that connects Codex to Autodesk Revit and
AutoCAD. The project uses one MCP protocol and shared connector core with
version-specific Autodesk adapters.

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
