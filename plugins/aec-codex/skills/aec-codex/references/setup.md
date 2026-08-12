# AEC Codex setup workflow

Use the scripts shipped inside the installed plugin. Never pipe a remote script
to `Invoke-Expression`, never replace the pinned release URL with `latest`, and
never skip the release SHA-256 check.

## Read-only preflight

Run `scripts/Get-AecCodexHostStatus.ps1` from the plugin root. Summarize:

- AEC Codex target and installed versions;
- Windows architecture and Python version;
- detected AutoCAD and Revit versions;
- running Autodesk processes;
- missing, changed, or outdated installed files;
- the exact status and recommended next action.

The status script must complete before asking to install. If it reports an
unsupported platform or missing prerequisite, explain that issue instead of
attempting an installation.

## Consent boundary

Before an install, repair, upgrade, or uninstall, show the user:

- the exact AEC Codex version and pinned GitHub release URL;
- the expected SHA-256, or that the release has not been published yet;
- every current-user location that will be changed;
- that AutoCAD and Revit must be closed;
- that a private Python environment and pinned providers may be installed;
- that failure triggers rollback to the previous installation.

Ask one direct confirmation question. Continue only after an affirmative
response in the current task. Codex host approval prompts still apply; this
workflow does not weaken them.

## Install, repair, and upgrade

After consent, run `scripts/Install-AecCodexHost.ps1 -UserApproved` from the
plugin root. Add `-Action Repair` only for repair. Upgrade uses the normal
`Install` action when the status is `needs_upgrade`.

The script downloads one exact release, verifies SHA-256, and invokes the
packaged installer in `HostOnly` mode. It must not create a personal plugin,
edit a personal marketplace, or register a duplicate plugin.

When installation succeeds, tell the user to close and reopen Codex, Revit,
and AutoCAD, then start a new Codex task. In that new task, rerun the status
script and proceed only when it reports `healthy`.

## Uninstall

After consent, run
`scripts/Install-AecCodexHost.ps1 -Action Uninstall -UserApproved`. Host-only
uninstall removes AEC Codex connectors, providers, local MCP host files, and
installation state. It preserves the Codex marketplace plugin itself.

## Failure handling

- Report checksum mismatches without retrying another URL.
- If Autodesk is running, stop and ask the user to close it.
- If installation rolls back, report the original failure and that the prior
  installation was restored.
- Do not fall back to manual file deletion or a second installer automatically.
