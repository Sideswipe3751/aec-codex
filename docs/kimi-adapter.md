# Kimi Code adapter

## Status

The first Kimi adapter is experimental and targets Kimi Code CLI on Windows
x64. It mounts the existing BIM Bridge stdio MCP projection and does not certify
a new Contract-v2 adapter, Autodesk connector, or native Host release.

Official Kimi Code documentation confirms support for installable plugins,
directory-form Agent Skills, and local stdio MCP servers:

- [Kimi Code plugins](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/plugins)
- [Kimi Code Agent Skills](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/skills.html)
- [Kimi Code MCP](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/mcp.html)

## Components

- `kimi.plugin.json` is the repository-root Kimi plugin manifest. It exposes the
  Kimi Skill and one relative, plugin-contained stdio launcher command.
- `adapters/kimi/skills/bim-bridge/SKILL.md` contains Kimi-specific lifecycle,
  approval, and verification guidance.
- `Get-BimBridgeKimiStatus.ps1` is a read-only Kimi Code and Host preflight.
- `Get-BimBridgeKimiMcpConfig.ps1` emits a project-level MCP JSON fallback but
  does not write `.kimi-code/mcp.json`.
- `Start-BimBridgeKimiMcp.ps1` validates the installed neutral Host launcher
  path and SHA-256, sets the Kimi adapter identity, and delegates stdio to it.

## Distribution and trust

Kimi Code can install the repository plugin from a GitHub branch, tag, commit,
release, local directory, or zip. The current development command targets the
`main` branch. A public release should use a signed, immutable release/tag and
the separately published BIM Bridge Host archive.

Kimi installs plugins per user and loads their Skills and MCP declarations in a
new session or after `/reload`. Its managed copy is independent from the source
checkout. A project-level `.kimi-code/mcp.json` is an explicit debugging
fallback and triggers Kimi's workspace trust review.

Neither route is native Host installation consent. The adapter stops when Host
state is missing, incomplete, or changed.

## Deliberate omissions

The initial adapter does not:

- edit Kimi user data or `.kimi-code/mcp.json`;
- install, repair, upgrade, or uninstall the BIM Bridge Host;
- copy Codex bootstrap or installer logic;
- rename the existing `aec_*` compatibility tools;
- add Kimi policy, routing, transaction, or Autodesk behavior to the Runtime;
- grant blanket MCP permissions or bypass Kimi approval controls;
- claim live Kimi certification.

## Acceptance

1. Run `tests/adapters/kimi/Test-KimiAdapter.ps1`.
2. Install the local repository plugin in Kimi Code and inspect it with
   `/plugins info bim-bridge`.
3. Run `/reload` or start a new Kimi session, then confirm `bim-bridge` is
   connected with `/mcp`.
4. Confirm the first relevant Skill activation returns healthy read-only status.
5. In a disposable Autodesk document, verify discovery, document read, one
   previewed bounded write, committed readback, intentional rollback/readback,
   and focused view capture when appearance matters.

Record Kimi-specific tool naming, plugin diagnostics, permission behavior, and
restart requirements only in this adapter and its tests unless the architecture
contract explicitly requires a broader update.
