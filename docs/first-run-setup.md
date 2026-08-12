# First-run setup

AEC Codex separates the Codex plugin from the Windows host components loaded by
AutoCAD and Revit. Installing the plugin makes the setup skill and read-only
status script available; it does not itself install Autodesk add-ins.

## User flow

1. Install AEC Codex from the public Plugins Directory. Before public approval,
   release-candidate testers may use the version-pinned repository marketplace.
2. Restart Codex and start a new task with the setup starter prompt.
3. Codex runs `Get-AecCodexHostStatus.ps1`. This does not modify the computer.
4. Codex reports platform support, product versions, running applications,
   exact paths, external MCP status, release URL, and SHA-256.
5. The user explicitly approves or declines the proposed host changes.
6. After approval, `Install-AecCodexHost.ps1` downloads and verifies one exact
   host release and invokes `Install-AecCodex.ps1 -InstallMode HostOnly`.
7. The user restarts Codex and Autodesk, opens a new task, and reruns the health
   check.

Installing the Marketplace plugin is not approval for step 6. If approval is
declined, no installation command is run.

## Status values

| Status | Meaning | Next action |
| --- | --- | --- |
| `not_installed` | No host state or partial files exist | Review and approve install |
| `needs_prerequisite` | The PC is not supported Windows x64 | Use a supported PC |
| `needs_repair` | State, a recorded file, private runtime, or external MCP registration is missing/changed | Review and approve repair |
| `needs_upgrade` | The installed host differs from the plugin target version | Review and approve upgrade |
| `restart_required` | The current Codex process predates host installation | Restart Codex and Autodesk |
| `healthy` | Version, private runtime, MCP registration, and recorded file hashes pass | Continue to MCP discovery |

## Changed locations

HostOnly setup is limited to the current user:

- `%APPDATA%\Autodesk\ApplicationPlugins\AEC Codex.bundle`
- `%APPDATA%\Autodesk\Revit\Addins\2024`
- `%LOCALAPPDATA%\AEC Codex`
- `%USERPROFILE%\.codex\config.toml` (the `aec-codex-local` MCP registration)

It does not copy a plugin into `~/plugins`, edit
`~/.agents/plugins/marketplace.json`, or call `codex plugin add`. It does not
require a system Python installation and does not run `pip` on the user PC.

## Failure and rollback

The bootstrap refuses unpublished releases, missing hashes, and checksum
mismatches. AutoCAD and Revit must be closed before installation. The main
installer and provider installer preserve their previous targets until every
step succeeds; a failure restores those backups and the prior Codex MCP
configuration, then reports the original error.
No alternate URL or manual deletion fallback runs automatically.

Host-only uninstall uses the maintenance copy installed under
`%LOCALAPPDATA%\AEC Codex\maintenance`, removes `aec-codex-local`, and
preserves the public plugin.
