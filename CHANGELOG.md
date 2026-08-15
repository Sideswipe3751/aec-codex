# Changelog

## 2.0.0-alpha.1 - 2026-08-15

- Added one shared, matrix-driven AutoCAD host for certified AutoCAD 2024-2027.
- Added exact modern-runtime and Roslyn resolution for AutoCAD 2025-2027.
- Added unattended exact-version AutoCAD acceptance and release-package tests.
- Added a signed preview Host manifest, immutable Windows x64 archive packaging,
  and read-only package validation.

All notable changes to BIM Bridge are documented in this file. Historical
release entries retain the AEC Codex name used by those published artifacts.

The project follows Semantic Versioning. Release candidates may contain known
limitations and are intended for cross-machine compatibility testing.

## [Unreleased]

### Added

- Added the lightweight `bim-bridge` Codex plugin and per-task bootstrap Skill.
- Added a transactional BIM Bridge Host installer, external
  `bim-bridge-local` MCP launcher, schema-4 install state, file hashing, and
  recoverable migration of known legacy AEC Codex components.
- Extended the single Autodesk version matrix to cover certified AutoCAD 2024
  alongside the certified Revit 2024-2027 variants.

### Changed

- Renamed the product to BIM Bridge while retaining legacy package, skill,
  assembly, script, and state identifiers until the installer migration.
- Extracted host and provider ownership into the agent-independent BIM Bridge
  Runtime and reduced the Codex MCP server to a compatibility projection.
- Added explicit capability routing, effect policy, request-bound approvals,
  verification normalization, and correlated redacted audit records.
- Added runtime-owned adapter sessions, signed approval grants, a unified
  contract-v2 host execution pipeline, UI-thread target drift rejection,
  read-back verification, and a hash-chained execution journal.
- Reclassified arbitrary in-process query code as a critical ambient-authority
  operation and changed its MCP annotations from read-only to destructive.
- Changed provider reloads to validate and atomically switch generations while
  draining replaced child processes.
- Made the Codex skill an implicit per-task bootstrap adapter: it performs the
  shared read-only host check on first relevant activation, requires explicit
  current-task consent before native installation changes, and documents the
  same bootstrap lifecycle for future agent adapters without claiming an idle
  session-start hook.
- Split plugin installation from native Host consent: installing the Codex
  plugin adds only the Skill/bootstrap layer, while Host installation remains a
  separate approved operation and optional structured providers stay excluded.

### Validation

- Version 1 tool names and connector routes remain compatible. Its canonical
  fixture was intentionally revised for the dynamic-query security annotation.
- Runtime, provider, policy, adapter, and contract-v2 tests cover deterministic
  routing, no post-execution fallback, exact write targets, approval replay
  refusal, evidence normalization, and legacy facade compatibility.
- Unattended compatibility-facade live acceptance passed on Revit 2024.1,
  2025.4, 2026.5, and 2027.2, including exact target routing, committed-write
  read-back, intentional rollback/read-back, dependency isolation, clean
  shutdown, and descriptor cleanup. Run IDs: `12cf53af848f4298990847d5ef508872`,
  `970b188ccb864d019e3a1a82d9f61c44`, `ecfb027ff5404f22a058489a177a8952`,
  and `f7d0981d79db44568dda8edf097cd68b`.
- AutoCAD 2024 unattended compatibility-facade live acceptance passed with run
  ID `fa9db225cbb64690884a2bd9bdcb6426`; direct contract-v2 adapter certification
  remains a separate gate.

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

[Unreleased]: https://github.com/Sideswipe3751/bim-bridge/compare/v1.1.0-rc.3...HEAD
[1.1.0-rc.3]: https://github.com/Sideswipe3751/aec-codex/compare/v1.1.0-rc.2...v1.1.0-rc.3
[1.1.0-rc.2]: https://github.com/Sideswipe3751/aec-codex/compare/v1.1.0-rc.1...v1.1.0-rc.2
[1.1.0-rc.1]: https://github.com/Sideswipe3751/aec-codex/releases/tag/v1.1.0-rc.1
