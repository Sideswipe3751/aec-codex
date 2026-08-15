# First-run setup

BIM Bridge separates the Codex Skill from the Windows Host components loaded by
AutoCAD and Revit. Installing the `bim-bridge` plugin makes the setup workflow
and read-only status script available; it is not consent to install Autodesk
add-ins or register the local MCP Host.

## User flow

1. Install the lightweight BIM Bridge Codex plugin.
2. Restart Codex and start a new task about BIM Bridge, Revit, or AutoCAD.
3. On its first relevant activation, the Skill runs
   `Get-BimBridgeHostStatus.ps1`. This does not modify the computer.
4. Codex reports the target version, installed products, running Autodesk
   processes, exact paths, external MCP status, release source, and integrity
   state.
5. The user explicitly approves or declines the proposed Host changes.
6. After approval, `Install-BimBridgeHost.ps1` verifies the published archive
   and checksum, or uses the explicit trusted source root of a development
   plugin, then invokes `Install-BimBridge.ps1`.
7. The user restarts Codex and Autodesk, opens a new task, and reruns the health
   check.

Installing the Codex plugin is not approval for step 6. There is no idle
task-start hook: bootstrap begins when Codex first invokes the Skill for a
relevant request. If approval is declined, no installation command is run.

## Status values

| Status | Meaning | Next action |
| --- | --- | --- |
| `not_installed` | No Host state or partial files exist | Review and approve install |
| `needs_prerequisite` | The PC is not supported Windows x64 | Use a supported PC |
| `needs_repair` | State, a recorded file, private runtime, or external MCP registration is missing/changed | Review and approve repair |
| `needs_upgrade` | The installed Host differs from the plugin target version | Review and approve upgrade |
| `restart_required` | The current Codex process predates Host installation | Restart Codex and Autodesk |
| `healthy` | Version, private runtime, MCP registration, and recorded file hashes pass | Continue to MCP discovery |

## Changed locations

The development installer is limited to the current user:

- `%LOCALAPPDATA%\BIM Bridge`
- `%APPDATA%\Autodesk\ApplicationPlugins\BIM Bridge.bundle`
- `%APPDATA%\Autodesk\Revit\Addins\<certified-installed-version>\BIM.Bridge.addin`
- `%USERPROFILE%\.codex\config.toml` (the `bim-bridge-local` MCP registration)

It discovers installed Autodesk products and deploys only matching entries that
the single repository version matrix already marks certified. It includes a
private Python runtime and does not require system Python or run `pip` on the
user PC. Structured providers are optional and are not installed by the current
development alpha.

With explicit legacy migration, the same transaction removes only known
installer-owned AEC Codex Host, provider, Autodesk manifest/bundle, state-file,
and `aec-codex-local` registration targets. Unknown legacy data, logs, and
development trust remain in place. Removing the old Codex plugin itself is a
separate plugin-manager operation.

## Failure and rollback

The bootstrap refuses unpublished remote releases, missing hashes, and checksum
mismatches. AutoCAD and Revit must be closed before any Host mutation. Install,
repair, migration, and uninstall preserve their previous targets until the
transaction succeeds; a failure restores file targets and prior Codex MCP
registrations, then reports the original error. No alternate URL or manual
deletion fallback runs automatically.
