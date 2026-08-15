# Kimi Code adapter setup

This experimental adapter connects Kimi Code to an already installed neutral
BIM Bridge Host. It does not install, repair, upgrade, or uninstall that Host.

## Read-only status

Run `../scripts/Get-BimBridgeKimiStatus.ps1` relative to this file and report:

- detected Kimi Code executable and version;
- BIM Bridge install-state path and schema;
- installed Host version;
- launcher, private Python, and MCP server integrity;
- running Revit and AutoCAD processes;
- exact missing or changed critical files.

Continue only when the returned status is `healthy`.

## Plugin configuration

The repository root `kimi.plugin.json` declares this Skill and the `bim-bridge`
stdio MCP server. Kimi Code can install a local checkout, zip URL, or GitHub
repository through `/plugins install <path-or-url>`. Run `/reload` or start a
new session after installation, enablement, or source update. Use `/plugins
info bim-bridge` and `/mcp` for diagnostics.

Kimi copies installed plugins into its managed data directory. Editing the
original checkout does not update that managed copy; reinstall the plugin or
use the project-level debugging method below.

## Project-level debugging

Run `../scripts/Get-BimBridgeKimiMcpConfig.ps1` to generate a JSON object with
the exact absolute path of this adapter's verified launcher wrapper. Merge only
the returned `bim-bridge` entry into the project `.kimi-code/mcp.json`; do not
overwrite other servers and do not write user-level Kimi configuration.

Load the Skill from `adapters/kimi/skills`, start a new session, review the
workspace trust prompt, and confirm the server with `/mcp`. The checked-in
`adapters/kimi/mcp.template.json` is documentation only and contains a
placeholder that must not be used unchanged.

## Host unavailable

If status is `not_installed` or `needs_repair`, stop. Report that Host mutation
must use the shared signed BIM Bridge release and installer workflow after
explicit user consent. Do not source-build an unpublished Host or copy Codex
bootstrap scripts into this adapter.
