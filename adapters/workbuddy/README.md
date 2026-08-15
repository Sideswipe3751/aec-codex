# BIM Bridge for WorkBuddy

This directory contains the experimental Tencent WorkBuddy compatibility layer.
It reuses the installed BIM Bridge Host and existing stdio MCP server; it does
not contain Autodesk code or a WorkBuddy-specific Runtime.

## Marketplace installation

Paste the repository's canonical request into WorkBuddy:

> 请从 https://github.com/Sideswipe3751/bim-bridge 安装并配置 BIM Bridge。

The deterministic WorkBuddy commands are:

```text
/plugin marketplace add https://github.com/Sideswipe3751/bim-bridge
/plugin install bim-bridge@bim-bridge
```

The Marketplace plugin installs this Skill and its `.mcp.json` declaration as
one relocatable unit. Restart or reload WorkBuddy plugins, then start a new
task. Plugin installation is not consent to install or repair the native Host.

## Local development fallback

1. In WorkBuddy, set this repository as the task workspace so the root
   `CODEBUDDY.md` scope is loaded.
2. Add this local checkout as a WorkBuddy Marketplace and install
   `bim-bridge@bim-bridge`, or import `skills/bim-bridge` only for isolated Skill
   development.
3. Generate an absolute-path MCP configuration:

   ```powershell
   & .\adapters\workbuddy\skills\bim-bridge\scripts\Get-BimBridgeWorkBuddyMcpConfig.ps1
   ```

4. When testing without the Marketplace plugin, paste the returned
   `mcpServers` object into WorkBuddy's custom MCP editor. Do not overwrite
   other configured servers.
5. Restart or reconnect WorkBuddy's MCP services, then ask it to check BIM
   Bridge status.

The generator is read-only and does not edit WorkBuddy user data. The MCP
wrapper validates the installed Host launcher location and SHA-256 before
starting it.

## Current boundary

This version assumes the neutral BIM Bridge Host is already installed. If
the Host is missing or unhealthy, the Skill reports the state and stops. Native
Host install, repair, upgrade, release publishing, and WorkBuddy configuration
file discovery remain outside this experimental adapter.

See [the adapter guide](../../docs/workbuddy-adapter.md) for debugging and
acceptance criteria.
