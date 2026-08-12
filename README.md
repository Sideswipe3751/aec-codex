# AEC Codex

[![CI](https://github.com/Sideswipe3751/aec-codex/actions/workflows/ci.yml/badge.svg)](https://github.com/Sideswipe3751/aec-codex/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Sideswipe3751/aec-codex?include_prereleases)](https://github.com/Sideswipe3751/aec-codex/releases)

AEC Codex is a local Codex plugin that connects Codex to Autodesk Revit and
AutoCAD. It combines dynamically discovered structured MCP tools with an
authenticated, version-aware Autodesk connector for document inspection,
selection reads, bounded API execution, and transaction-safe writes.

> [!IMPORTANT]
> AEC Codex is an early release candidate. Use disposable drawings and models
> for write testing, keep backups, and review the support matrix below.

## Capabilities

- Discovers local Revit and AutoCAD sessions without exposing a network port
  beyond loopback.
- Routes structured operations through pinned Revit and AutoCAD MCP providers.
- Previews writes before execution and keeps Codex as the user-facing approval
  layer.
- Falls back to authenticated, bounded Autodesk API code when a structured tool
  does not cover the required operation.
- Uses native transactions or undo groups when atomic rollback is appropriate.
- Installs per Windows user and rolls installation changes back on failure.

## Support matrix

| Product | Version | Runtime | Status |
| --- | --- | --- | --- |
| AutoCAD | 2024 / R24.3 | .NET Framework 4.8 | Release candidate; live structured-provider and rollback testing completed |
| Revit | 2024 | .NET Framework 4.8 | Release candidate; final live acceptance pending |
| AutoCAD / Revit | 2025-2026 | .NET 8 compatibility line | Not implemented or supported |
| AutoCAD / Revit | 2027 | .NET 10 compatibility line | Planned; not implemented or supported |

No Autodesk version is considered certified until its exact connector and a
representative set of read/write operations pass inside that product.

## Architecture

- `plugins/aec-codex`: Codex plugin, AEC skill, and dependency-free MCP host.
- `protocol`: versioned connector discovery and request contracts.
- `providers`: pinned upstream builds, security patches, schema snapshots, and
  controlled update commands.
- `src`: shared bridge and version-specific Autodesk connector projects.
- `tests`: MCP, bridge, provider-bundle, and live acceptance tests.
- `installer`: current-user install, repair, uninstall, bootstrap, and release
  packaging scripts.
- `docs`: architecture, security, compatibility, and live-test notes.

Connectors publish short-lived descriptors under the current user's profile.
The MCP host accepts only `127.0.0.1` connector URLs and authenticates every
request with a per-process bearer token. See [the architecture notes](docs/architecture.md).

## Install a release candidate

Prerequisites:

- Windows x64
- Codex desktop app or CLI
- Python 3 available as `python`
- Internet access during the first AutoCAD provider dependency installation
- AutoCAD 2024 and/or Revit 2024 for the connector being tested

Download the ZIP and matching `.sha256` file from
[GitHub Releases](https://github.com/Sideswipe3751/aec-codex/releases), verify
the checksum, close Revit and AutoCAD, extract the ZIP, and run:

```powershell
& .\installer\Install-AecCodex.ps1 -SkipBuild
```

Restart Codex and the Autodesk applications after installation. Start a new
Codex task so it loads the new plugin and provider catalogs. In Revit, click
**Revit MCP Switch** once per session to start the structured-provider
listener.

Repair or uninstall the current-user installation with:

```powershell
& .\installer\Install-AecCodex.ps1 -Action Repair -SkipBuild
& .\installer\Install-AecCodex.ps1 -Action Uninstall
```

## Build and install from source

A full connector build requires the .NET SDK plus local AutoCAD 2024 and Revit
2024 installations at their default paths. Close both Autodesk applications,
then run:

```powershell
& .\installer\Install-AecCodex.ps1
```

The installer builds the solution and verified provider bundles, installs the
connectors for the current user, registers the personal Codex plugin, and
restores the previous installation if any step fails.

Check pinned upstreams without activating them:

```powershell
& .\providers\Update-AecProviders.ps1 -Action Check
```

Provider activation is versioned. Server and schema updates take effect in a
new Codex task; a changed Revit provider add-in also requires a Revit restart.
`-Action Rollback` swaps back to the previous active provider configuration.

## Test

Run the dependency-free MCP tests and shared bridge tests:

```powershell
python -m unittest discover -s tests\mcp -p "test_*.py"
dotnet run --project tests\Aec.Codex.Bridge.Tests -c Release -f net10.0
```

When verified provider artifacts are available, also run:

```powershell
& .\providers\Test-ProviderBundles.ps1
```

The Autodesk 2024 manual acceptance sequence is documented in
[docs/live-test-2024.md](docs/live-test-2024.md).

## Create a release ZIP

Maintainers create a Windows release ZIP and checksum with:

```powershell
& .\installer\New-AecCodexRelease.ps1 -Version '1.1.0-rc.1'
```

The public bootstrap downloads a release ZIP, verifies its SHA-256, and only
then runs the packaged installer. It never pipes an unverified remote script
into `Invoke-Expression`.

## Contributing and security

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request. Please report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md), not in a public issue.

## License and trademarks

AEC Codex original code is licensed under the
[Apache License 2.0](LICENSE). Bundled third-party components remain under
their respective licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Autodesk, AutoCAD, and Revit are trademarks or registered trademarks of
Autodesk, Inc. AEC Codex is not affiliated with or endorsed by Autodesk.
