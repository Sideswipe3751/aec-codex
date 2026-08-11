# AEC Codex

AEC Codex is a local Codex plugin that connects Codex to Autodesk Revit and
AutoCAD. The project uses one MCP protocol and shared connector core with
version-specific Autodesk adapters.

## V1.0 goal

AEC Codex V1.0 provides a complete local experience: one-command current-user
installation, dynamically discovered structured tools from
`mcp-servers-for-revit` and `U-C4N/Autocad-MCP`, live document and selection
reads, previewed writes, dynamic Autodesk API fallback, and atomic rollback for
failed fallback writes. Codex remains the only user-facing approval layer.

## V1.0 support targets

| Product | Version | Runtime | Release gate |
| --- | --- | --- | --- |
| Revit | 2024 | .NET Framework 4.8 | Provider/connector candidate; live acceptance pending |
| AutoCAD | 2024 | .NET Framework 4.8 | Provider/connector candidate; live acceptance pending |
| Revit | 2027 | .NET 10 | Planned compatibility line; not yet certified |
| AutoCAD | 2027 | .NET 10 | Planned compatibility line; not yet certified |

The shared bridge and tests already target .NET 10, but Autodesk 2027 adapter
projects and structured-provider compatibility are a separate milestone. No
Autodesk version is certified until its exact connector and representative
read/write operations pass inside that product.

## Repository layout

- `plugins/aec-codex`: Codex plugin, AEC skill, and dependency-free MCP host.
- `protocol`: versioned connector discovery and request contracts.
- `providers`: pinned upstream builds, security patches, schema snapshots, and
  controlled update commands.
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

The installer builds the solution and verified provider bundles, installs the
Revit 2024 and AutoCAD 2024 connectors plus the structured providers for the
current Windows user, registers the personal Codex plugin, and rolls every
changed path back if installation fails. Restart Codex and the Autodesk
applications after installation. Use `-Action Repair` to reinstall or
`-Action Uninstall` to remove it.

Check pinned upstreams against their latest GitHub releases without activating
anything:

```powershell
& .\providers\Update-AecProviders.ps1 -Action Check
```

Provider activation is versioned. Server/schema updates take effect in a new
Codex task; a changed Revit provider add-in also requires a Revit restart.
`-Action Rollback` swaps back to the previous active provider configuration.

The final Autodesk 2024 acceptance sequence is documented in
[`docs/live-test-2024.md`](docs/live-test-2024.md).

The public bootstrap downloads a release ZIP and verifies its SHA-256 before
running the packaged installer; it never pipes an unverified remote script into
`Invoke-Expression`.

Maintainers create that self-contained Windows ZIP and checksum with:

```powershell
& .\installer\New-AecCodexRelease.ps1
```
