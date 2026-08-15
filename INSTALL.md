# Install BIM Bridge with a supported agent

The public installation request is intentionally the same one sentence in
Codex, WorkBuddy, Kimi Code, and future supported agents:

> 请从 https://github.com/Sideswipe3751/bim-bridge 安装并配置 BIM Bridge。

## Agent dispatch rule

Identify the current agent platform, then install only that platform's thin BIM
Bridge adapter. Do not install another agent's adapter merely because its files
exist in this repository. Adapter installation is separate from native Host
installation and is not consent to modify Autodesk or native Host state.

## Codex

Treat this repository as a Codex Repo Marketplace. Do not install only the
Skill, run an unpinned remote PowerShell command, or build the native Host from
source for an ordinary remote user.

On a supported Windows x64 machine with Codex installed:

```powershell
codex plugin marketplace add Sideswipe3751/bim-bridge --ref main
codex plugin add bim-bridge@bim-bridge
```

If the Marketplace is already configured, refresh it before reinstalling:

```powershell
codex plugin marketplace upgrade bim-bridge
codex plugin add bim-bridge@bim-bridge
```

After the Plugin command succeeds:

1. Ask the user to restart Codex and open a new task about BIM Bridge, Revit,
   or AutoCAD. Skills and tools are loaded at the new-task boundary.
2. Let the installed BIM Bridge Skill run its bundled read-only Host status
   check. Do not download or substitute a status script.
3. If Host installation, repair, or upgrade is required, show the exact version,
   release URL, SHA-256, current-user locations, running Autodesk constraints,
   MCP registration, and rollback behavior.
4. Obtain affirmative consent after showing that plan. The original request to
   install the Plugin is not consent to mutate Autodesk or native Host state.
5. Run only the installer bundled with the Plugin. It must accept a remote Host
   release only when the release manifest marks it published and supplies a
   pinned URL and valid SHA-256.
6. After a Host change, require the documented Codex and Autodesk restart, then
   verify status in another new task.

## Tencent WorkBuddy

Treat this repository as a WorkBuddy/CodeBuddy Plugin Marketplace. The plugin
contains the WorkBuddy Skill and its relocatable MCP declaration, so do not
copy the Skill alone or edit a private WorkBuddy MCP file.

In WorkBuddy, add the Marketplace and install its one plugin:

```text
/plugin marketplace add https://github.com/Sideswipe3751/bim-bridge
/plugin install bim-bridge@bim-bridge
```

If the Marketplace already exists, refresh it before reinstalling:

```text
/plugin marketplace update
/plugin install bim-bridge@bim-bridge
```

Restart WorkBuddy or reload plugins, then start a new task about BIM Bridge,
Revit, or AutoCAD. The installed Skill runs its bundled read-only status check.
The WorkBuddy plugin does not install or repair the native Host; when Host work
is needed it reports the exact state and keeps the separate consent boundary.

## Kimi Code

Treat the repository-root `kimi.plugin.json` as the Kimi Code plugin entry. In
Kimi Code, install the repository plugin and reload:

```text
/plugins install https://github.com/Sideswipe3751/bim-bridge/tree/main
/reload
```

Start a new Kimi session about BIM Bridge. Kimi loads only its own Skill and
MCP declaration. Its experimental adapter reports a missing or unhealthy Host
and stops; it does not install or repair native components.

The current development manifest is deliberately unpublished. Until a signed
Host archive and checksum are released, an external user can install the Codex
Plugin but the Plugin must refuse remote Host installation. Do not bypass that
gate by cloning the repository, setting a development source root, choosing an
unverified `latest` download, or compiling from source.

## Contributor-only local development

Repository contributors who intentionally trust their local checkout may add
its root as a local Codex Marketplace:

```powershell
codex plugin marketplace add 'C:\path\to\bim-bridge'
codex plugin add bim-bridge@bim-bridge
```

Local Host development uses the repository installer only after the same
read-only preflight and explicit Host consent. It is not the public beta
distribution path.
