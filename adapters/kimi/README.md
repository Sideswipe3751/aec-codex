# BIM Bridge for Kimi Code

This directory contains the experimental Kimi Code compatibility layer. It
reuses the installed, agent-independent BIM Bridge Host and existing stdio MCP
projection. It contains no Autodesk implementation or Kimi-specific Runtime.

## Plugin setup

The repository root `kimi.plugin.json` lets Kimi Code install this adapter from
the repository. During local development, run this inside Kimi Code:

```text
/plugins install https://github.com/Sideswipe3751/bim-bridge/tree/main
/reload
```

Start a new session after installation. The plugin contributes the BIM Bridge
Skill and starts the MCP server through the verified wrapper in this directory.
Installing the plugin is not consent to install or repair the native Host.

## Project-level debugging fallback

To test an edited checkout without reinstalling the managed plugin copy:

1. Generate an absolute-path MCP configuration:

   ```powershell
   & .\adapters\kimi\skills\bim-bridge\scripts\Get-BimBridgeKimiMcpConfig.ps1
   ```

2. Merge the returned `bim-bridge` entry into `.kimi-code/mcp.json`. Do not
   overwrite other configured servers.
3. Launch Kimi Code with this Skill directory when needed:

   ```powershell
   kimi --skills-dir .\adapters\kimi\skills
   ```

4. Review Kimi's workspace trust prompt, then use `/mcp` to confirm the server
   is connected.

The generator is read-only. It never edits Kimi user or project configuration.
The MCP wrapper verifies the installed Host launcher location and SHA-256 before
delegating stdio to it.

## Current boundary

This initial version requires the neutral BIM Bridge Host to be installed and
healthy. It reports and stops on missing or changed Host files. Host install,
repair, upgrade, uninstall, signing, and release publishing remain outside the
Kimi adapter.

See [the adapter guide](../../docs/kimi-adapter.md) for acceptance criteria.
