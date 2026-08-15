# BIM Bridge WorkBuddy development scope

This file is the project-level instruction file for Tencent WorkBuddy and
CodeBuddy. It deliberately contains the complete WorkBuddy scope because
`CODEBUDDY.md` takes precedence over the repository `AGENTS.md` compatibility
fallback.

## Current objective

Develop and debug only the experimental Tencent WorkBuddy compatibility layer
for BIM Bridge. The adapter must remain a thin client of the existing BIM Bridge
MCP projection and the versioned BIM Bridge Contract. It must not copy or fork
the Runtime, Autodesk connectors, provider routing, policy, transactions, or
installation state model.

Before changing implementation, tests, packaging, configuration, or installer
behavior, read `docs/architecture.md` in full. Treat it as the architecture
contract. If an implementation decision makes it inaccurate, update it in the
same change.

## Default writable scope

WorkBuddy may create or modify only these paths without asking the user to
expand the task:

- `adapters/workbuddy/**`
- `tests/adapters/workbuddy/**`
- `.codebuddy-plugin/marketplace.json`
- `docs/workbuddy-adapter.md`
- `CODEBUDDY.md`
- the WorkBuddy-specific section of `README.md`
- the WorkBuddy-specific section of `INSTALL.md`
- the WorkBuddy assertions in `tests/plugin/Test-BimBridgeRepoInstall.ps1`
- the WorkBuddy adapter test step in `.github/workflows/ci.yml`
- `docs/architecture.md` only when required to keep the architecture contract
  accurate

Preserve unrelated user changes in these files. Keep changes focused on the
WorkBuddy adapter and its tests.

## Read-only reference scope

WorkBuddy may inspect these paths to understand existing contracts, but must not
modify them unless the user explicitly expands the scope:

- `runtime/**`
- `protocol/**`
- `plugins/bim-bridge/**`
- `plugins/aec-codex/**`
- `installer/**`
- `providers/**`
- `src/**`
- `eng/**`
- `tests/mcp/**`
- `tests/runtime/**`
- `tests/protocol/**`
- `tests/installer/**`

## Prohibited changes

Without a new, explicit user instruction, do not:

- modify the BIM Bridge Runtime or create a WorkBuddy-specific runtime;
- change the frozen version-1 tool names, schemas, connector routes, or
  `protocol/v1/baseline.json`;
- change contract-v2 schemas or introduce a WorkBuddy-only domain model;
- modify Revit or AutoCAD source, assemblies, manifests, version support, or
  the Autodesk version matrix;
- change Codex or DeepSeek adapter behavior;
- change the native Host installer, release manifest, signing, migration,
  rollback, or uninstall behavior;
- write directly to `%LOCALAPPDATA%\BIM Bridge`, Autodesk add-in locations,
  WorkBuddy user data, or any MCP configuration outside this repository;
- build or publish a release, create a tag, commit, push, or open a pull request;
- delete or move files outside `adapters/workbuddy/**` and
  `tests/adapters/workbuddy/**`;
- bypass WorkBuddy approval prompts or treat Full Access as permission to
  weaken BIM Bridge policy.

If progress requires one of these operations, stop and ask the user to expand
the scope. Explain the exact file or external location and why it is required.

## Adapter invariants

- Use the installed neutral BIM Bridge Host launcher recorded in
  `%LOCALAPPDATA%\BIM Bridge\install-state.json`.
- Validate that the launcher resolves beneath the BIM Bridge Host root and
  matches its recorded SHA-256 before starting it.
- Expose the existing MCP tools unchanged. Current `aec_*` names are version-1
  compatibility identifiers, not WorkBuddy-owned names.
- Run the bundled read-only WorkBuddy status probe at the first relevant Skill
  activation in a task.
- Do not install or repair the native Host from this experimental adapter.
  Report the state and stop when the Host is missing or unhealthy.
- Present WorkBuddy as the single approval UI, while leaving policy, exact
  target enforcement, transactions, rollback, and verification in BIM Bridge.
- Discover providers and schemas through MCP. Do not hard-code provider
  precedence or use dynamic code as fallback after a denied or failed write.
- Preview writes when the selected tool supports dry run, then read back and
  verify affected objects.

## Initial adapter layout

- `adapters/workbuddy/skills/bim-bridge/SKILL.md`: WorkBuddy-facing workflow.
- `adapters/workbuddy/skills/bim-bridge/scripts/`: read-only status, MCP config
  generation, and verified Host launcher wrapper.
- `adapters/workbuddy/skills/bim-bridge/references/`: setup and debugging notes.
- `adapters/workbuddy/mcp.template.json`: human-readable stdio configuration
  shape; generate an absolute-path version with the bundled script.
- `tests/adapters/workbuddy/Test-WorkBuddyAdapter.ps1`: portable adapter tests.

## Validation

Run these checks after changing the adapter:

```powershell
& .\tests\adapters\workbuddy\Test-WorkBuddyAdapter.ps1
& .\tests\plugin\Test-BimBridgeRepoInstall.ps1
python -m unittest discover -s tests\mcp -p "test_*.py"
```

Also run `git diff --check` and inspect `git status --short`. Do not claim live
WorkBuddy certification until the adapter is loaded in WorkBuddy and completes
read, previewed write, rollback, readback, and focused visual verification in a
disposable Autodesk document.
