# Changelog

All notable changes to AEC Codex are documented in this file.

The project follows Semantic Versioning. Release candidates may contain known
limitations and are intended for cross-machine compatibility testing.

## [Unreleased]

### Planned

- Dedicated .NET 8 connectors for Autodesk 2025 and 2026.
- Dedicated .NET 10 connectors for Autodesk 2027.
- Cleaner AutoCAD rollback command handling and saved-state restoration.

## [1.1.0-rc.3] - 2026-08-11

### Added

- A self-contained, pinned Python 3.12.10 runtime for ordinary user installs.
- External `aec-codex-local` MCP registration with installer rollback and
  HostOnly uninstall handling.
- Public Skills-only submission builder, listing copy, legal/support pages,
  and positive/negative review test cases.
- Five original AEC Codex logo candidates for owner selection.

### Changed

- Removed the system Python prerequisite from the public HostOnly path.
- Moved AutoCAD provider dependency resolution to the trusted release build so
  first-run installation does not execute `pip` on the user's PC.
- Locked the complete AutoCAD Python dependency graph and verify its checksum
  before release, smoke-test, or development installation.

### Validation

- Windows PowerShell installer contracts, MCP unit tests, and the full .NET
  solution passed.
- The staged private runtime completed an MCP initialization handshake.
- AutoCAD and Revit provider bundles initialized with 47 and 25 allowed tools.
- The public submission ZIP contains only the Skill, setup scripts, legal
  metadata, release manifest, and license; native binaries and MCP metadata are
  excluded.

### Known issues

- Revit 2024 final live acceptance is still pending.
- Autodesk versions other than 2024 are not supported.

## [1.1.0-rc.2] - 2026-08-11

### Added

- Repository marketplace packaging for version-pinned Codex installation.
- First-task read-only setup, prerequisite, repair, upgrade, and restart status.
- Consent-gated host bootstrap with an immutable release URL and SHA-256.
- Installer contract tests for no-consent, checksum, state, repair, and
  HostOnly behavior.

### Changed

- Split native host installation from development personal-plugin
  registration with `HostOnly` and `Development` modes.
- Route the plugin MCP through a PowerShell launcher that prefers the installed
  versioned local host and reports missing Python clearly.
- Package the release ZIP as a host-only payload so its digest can be pinned
  outside the archive.

### Validation

- PowerShell 5.1 setup and installer contract tests passed.
- Plugin, Skill, MCP, bridge, and full solution validation passed.
- AutoCAD and Revit structured providers initialized with 47 and 25 allowed
  tools respectively.
- The host payload contains no release manifest, Skill bundle, local state,
  credentials, or key files, and its packaged core files match source hashes.

## [1.1.0-rc.1] - 2026-08-11

### Added

- Structured `mcp-servers-for-revit` and `U-C4N/Autocad-MCP` provider gateway.
- Pinned, checksummed provider builds and versioned activation.
- AutoCAD provider COM fixes for document-scoped variables, synchronous audit,
  deterministic line trimming, and grouped rollback.
- Authenticated local Revit 2024 and AutoCAD 2024 connector discovery.
- Transaction-safe Autodesk fallback execution.
- Current-user installer, repair, uninstall, bootstrap, and release packaging.
- Descriptor refresh recovery for transient Windows file sharing conflicts.
- Audited Revit runtime dependency refresh with zero known npm vulnerabilities
  at release build time.

### Validation

- AutoCAD 2024 structured provider reports 47 allowed tools.
- AutoCAD 2024 transaction rollback returned the drawing to 31 entities after
  creating test handle `537`; the handle was absent after rollback.
- No AutoCAD exception dialog appeared and subsequent provider reads succeeded.

### Known issues

- AutoCAD rollback may leave the drawing marked modified even when no test
  entity remains.
- The AutoCAD command history may show one transient `_UNDO` argument prompt.
- Revit 2024 final live acceptance is still pending.
- Autodesk versions other than 2024 are not supported.

[Unreleased]: https://github.com/Sideswipe3751/aec-codex/compare/v1.1.0-rc.3...HEAD
[1.1.0-rc.3]: https://github.com/Sideswipe3751/aec-codex/compare/v1.1.0-rc.2...v1.1.0-rc.3
[1.1.0-rc.2]: https://github.com/Sideswipe3751/aec-codex/compare/v1.1.0-rc.1...v1.1.0-rc.2
[1.1.0-rc.1]: https://github.com/Sideswipe3751/aec-codex/releases/tag/v1.1.0-rc.1
