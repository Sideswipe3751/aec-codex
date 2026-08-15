# WorkBuddy adapter setup

This experimental adapter connects WorkBuddy to an already installed neutral
BIM Bridge Host. It does not install, repair, upgrade, or uninstall that Host.

## Read-only status

Run `../scripts/Get-BimBridgeWorkBuddyStatus.ps1` relative to this file and
report:

- detected WorkBuddy version;
- BIM Bridge install-state path and schema;
- installed Host version;
- launcher, private Python, and MCP server integrity;
- running Revit and AutoCAD processes;
- exact missing or changed critical files.

Continue only when the returned status is `healthy`.

## MCP configuration

Run `../scripts/Get-BimBridgeWorkBuddyMcpConfig.ps1` to generate a JSON object
with the exact absolute path of the adapter's verified launcher wrapper. Merge
the returned `bim-bridge` entry into WorkBuddy's custom MCP editor without
overwriting other servers.

The checked-in `adapters/workbuddy/mcp.template.json` is documentation only.
Do not paste it without replacing its placeholder. Do not guess or write a
private WorkBuddy configuration path.

After configuring MCP, restart or reconnect WorkBuddy MCP services and start a
new task. If the server is unavailable, rerun the read-only status probe and
inspect WorkBuddy's MCP status UI before changing code.

## Host unavailable

If status is `not_installed` or `needs_repair`, stop. Report that Host mutation
is outside this initial adapter and must use the shared signed BIM Bridge release
and installer workflow after explicit user consent. Do not clone or copy the
Codex bootstrap scripts into this adapter.
