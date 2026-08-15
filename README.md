# BIM Bridge

[![CI](https://github.com/Sideswipe3751/bim-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/Sideswipe3751/bim-bridge/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Sideswipe3751/bim-bridge?include_prereleases)](https://github.com/Sideswipe3751/bim-bridge/releases)

BIM Bridge connects Codex—and, through the versioned contract, future agent
adapters—to Autodesk Revit and AutoCAD. Its agent-independent runtime combines
dynamically discovered structured tools with authenticated, version-aware host
connectors for inspection, bounded execution, policy-controlled writes,
verification, and correlated audit evidence.

> [!IMPORTANT]
> BIM Bridge 2.0 is a development alpha. Use disposable drawings and models
> for write testing, keep backups, and review the support matrix below.

## Capabilities

- Discovers local Revit and AutoCAD sessions without exposing a network port
  beyond loopback.
- Routes structured operations through pinned Revit and AutoCAD MCP providers.
- Previews writes before execution and keeps the active agent adapter as the
  single user-facing approval layer.
- Falls back to authenticated, explicitly approved Autodesk API code when a
  structured tool does not cover the required operation. Arbitrary query code
  is treated as ambient-authority code, not as a low-risk read tool.
- Uses native transactions or undo groups when atomic rollback is appropriate.
- Installs per Windows user and rolls installation changes back on failure.
- Includes a private, version-pinned Python runtime; end users do not need to
  install or configure Python.

## Support matrix

| Product | Version | Runtime | Status |
| --- | --- | --- | --- |
| AutoCAD | 2024 / R24.3 | .NET Framework 4.8 | Release candidate; live structured-provider and rollback testing completed |
| Revit | 2024.1 | .NET Framework 4.8 | Unattended live acceptance passed |
| Revit | 2025.4 | .NET 8 | Unattended live acceptance passed |
| Revit | 2026.5 | .NET 10 | Unattended live acceptance passed |
| Revit | 2027.2 | .NET 10 | Unattended live acceptance passed |

No Autodesk version is considered certified until its exact connector and a
representative set of read/write operations pass inside that product.

## Architecture

- `runtime/aec_runtime`: BIM Bridge Runtime host discovery, provider
  supervision, capability routing, policy, verification, and audit.
- `plugins/bim-bridge`: lightweight Codex Skill and approved Host bootstrap.
- `plugins/aec-codex/mcp-server`: version-1 compatibility MCP projection over
  the agent-independent runtime; packaged by the Host installer, not owned by
  the new Codex plugin.
- `protocol`: versioned BIM Bridge discovery and request contracts.
- `providers`: pinned upstream builds, security patches, schema snapshots, and
  controlled update commands.
- `src`: shared bridge, one matrix-driven Revit adapter, and Autodesk connector projects.
- `eng`: the single Autodesk version matrix and reusable adapter build entry points.
- `tests`: MCP, bridge, provider-bundle, and live acceptance tests.
- `installer`: current-user install, repair, uninstall, bootstrap, and release
  packaging scripts.
- `docs`: architecture, security, compatibility, and live-test notes.

Connectors publish short-lived descriptors under the current user's profile.
The MCP host accepts only `127.0.0.1` connector URLs and authenticates every
request with a per-process bearer token. See [the architecture notes](docs/architecture.md).

## Installation status

Prerequisites:

- Windows x64
- Codex desktop app or CLI
- AutoCAD 2024 and/or one of the certified Revit releases listed above

BIM Bridge 2.0 is not yet a signed public release. For local development, clone
this repository and add its root as a local marketplace:

```powershell
codex plugin marketplace add 'C:\path\to\bim-bridge'
```

Restart Codex, install **BIM Bridge** from the local marketplace, and start a
new task with the setup starter prompt.

The first task performs a read-only preflight. It reports the exact release,
SHA-256, prerequisites, running Autodesk applications, and current-user paths
before asking for permission. Only after the user confirms does Codex run the
approved host installer. The installer deploys the private runtime and
registers the external local MCP as `bim-bridge-local`.

Restart Codex and the Autodesk applications after host installation, then
start another new task for the health check. In Revit, click **Revit MCP
Switch** once per session to start the structured-provider listener. See
[the first-run guide](docs/first-run-setup.md) for the complete states and
recovery flow.

Ask BIM Bridge to repair or uninstall the host in a task. Both operations show
their planned current-user changes and require confirmation.

## Build and install from source

A Revit adapter build requires the .NET SDK and that exact Revit release at its
default path. Build every locally available matrix entry with:

```powershell
& .\eng\Build-RevitAdapters.ps1 -SkipUnavailable -Configuration Release
```

The Codex-only development installer discovers installed products from the
single Autodesk matrix and deploys only certified matching variants. Close all
Revit and AutoCAD sessions, then run:

```powershell
& .\installer\Install-BimBridge.ps1 -Action Install -MigrateLegacy
```

This installs the local Host and `bim-bridge-local` MCP registration. The
lightweight Codex plugin is installed separately; structured providers are not
included by default.

The installer builds the matrix-selected adapters, installs the connectors for
the current user, and restores the previous installation if any step fails.

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
dotnet run --project tests\BimBridge.Host.Tests -c Release -f net10.0
& .\tests\architecture\Test-RevitVersionArchitecture.ps1
```

When verified provider artifacts are available, also run:

```powershell
& .\providers\Test-ProviderBundles.ps1
```

The Autodesk 2024 manual acceptance sequence is documented in
[docs/live-test-2024.md](docs/live-test-2024.md).

## Release status

The current repository state is a local development alpha. Publishing remains
blocked until the BIM Bridge host archive, checksum, signing, and cross-machine
installation gates pass. The plugin release manifest intentionally remains
`published: false` until that work is complete.

## Contributing and security

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request. Please report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md), not in a public issue.

## License and trademarks

BIM Bridge original code is licensed under the
[Apache License 2.0](LICENSE). Bundled third-party components remain under
their respective licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Autodesk, AutoCAD, and Revit are trademarks or registered trademarks of
Autodesk, Inc. BIM Bridge is not affiliated with or endorsed by Autodesk.
