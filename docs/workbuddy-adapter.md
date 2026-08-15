# Tencent WorkBuddy adapter

## Status

The first WorkBuddy adapter is experimental and intended for local development
against Tencent WorkBuddy AI 5.1 or later on Windows x64. It mounts the existing
BIM Bridge stdio MCP projection and does not certify a new Contract-v2 adapter
or native Host release.

Official WorkBuddy documentation and the installed plugin contract confirm
support for Marketplace plugins that bundle Skills and custom stdio MCP
servers. WorkBuddy or CodeBuddy should open this repository as the workspace
when developing it so the root `CODEBUDDY.md` scope is loaded.

- [WorkBuddy local Skills](https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Skills-Market)
- [Custom MCP server configuration](https://www.workbuddy.cn/docs/ide/User-guide/MCP)
- [Project-level CODEBUDDY.md rules](https://www.workbuddy.cn/docs/ide/User-guide/Rules)

## Components

- `CODEBUDDY.md` defines WorkBuddy's writable scope and protected repository
  boundaries.
- `.codebuddy-plugin/marketplace.json` publishes the repository as a WorkBuddy
  Plugin Marketplace with one `bim-bridge` entry.
- `adapters/workbuddy/.codebuddy-plugin/plugin.json` installs the WorkBuddy
  Skill and relocatable MCP declaration as one plugin.
- `adapters/workbuddy/.mcp.json` uses `${CODEBUDDY_PLUGIN_ROOT}` and never
  embeds a contributor's absolute path.
- `adapters/workbuddy/skills/bim-bridge/SKILL.md` supplies WorkBuddy-specific
  lifecycle, approval, and verification guidance.
- `Get-BimBridgeWorkBuddyStatus.ps1` is a read-only adapter and Host preflight.
- `Get-BimBridgeWorkBuddyMcpConfig.ps1` remains a local-development fallback and
  generates exact custom MCP JSON without editing WorkBuddy user data.
- `Start-BimBridgeWorkBuddyMcp.ps1` validates the installed neutral Host launcher
  path and hash, sets the WorkBuddy adapter identity, and delegates stdio to it.

## Deliberate omissions

The adapter does not:

- discover or edit a private WorkBuddy configuration file; Marketplace install
  and removal are owned by WorkBuddy's plugin manager;
- install, repair, upgrade, or uninstall the BIM Bridge Host;
- copy Codex Plugin bootstrap scripts;
- rename the existing `aec_*` compatibility tools;
- add WorkBuddy policy, routing, transaction, or Autodesk implementation to the
  Runtime;
- claim live WorkBuddy certification.

## Local debugging

1. Run the portable adapter test:

   ```powershell
   & .\tests\adapters\workbuddy\Test-WorkBuddyAdapter.ps1
   ```

2. Add the local repository as a Marketplace and install
   `bim-bridge@bim-bridge`.
3. Reload plugins and verify the Skill and MCP server appear together.
4. Use the MCP JSON generator only when testing the documented fallback.
5. In a disposable Autodesk document, verify discovery, document read, one
   previewed bounded write, committed readback, intentional rollback, and a
   focused view capture when appearance matters.

Record any WorkBuddy-specific tool naming, plugin layout, permission, or restart
behavior only inside the adapter, its tests, and this document unless the user
explicitly expands `CODEBUDDY.md` scope.
