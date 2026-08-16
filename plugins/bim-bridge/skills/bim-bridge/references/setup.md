# BIM Bridge setup workflow

Use the scripts shipped inside the installed plugin. Never pipe a remote script
to `Invoke-Expression`, never replace the pinned release URL with `latest`, and
never skip the release SHA-256 check.

## Read-only preflight

Resolve the plugin root two directories above this skill directory, then run
`../../scripts/Get-BimBridgeHostStatus.ps1` relative to `SKILL.md`. Summarize:

- BIM Bridge target and installed versions;
- Windows architecture and whether the bundled private runtime is intact;
- whether the `bim-bridge-local` external MCP registration is present;
- detected AutoCAD and Revit versions;
- which exact installed Autodesk runtime variants are compatible and which will
  be skipped;
- running Autodesk processes;
- missing, changed, or outdated installed files;
- the exact status and recommended next action.

The status script must complete before asking to install. If it reports an
unsupported platform or missing prerequisite, explain that issue instead of
attempting an installation.

## Consent boundary

Before an install, repair, upgrade, or uninstall, show the user:

- the exact BIM Bridge version and pinned GitHub release URL;
- the expected SHA-256, or that the release has not been published yet;
- every current-user location that will be changed;
- that AutoCAD and Revit must be closed;
- that a self-contained private Python runtime, certified matching Autodesk
  connectors, and the `bim-bridge-local` MCP registration will be installed
  for the current user;
- that structured providers are optional and are not installed by this build;
- that incompatible Autodesk versions will be left untouched while compatible
  certified versions continue in the same installation;
- that failure triggers rollback to the previous installation.

Ask one direct confirmation question. Continue only after an affirmative
response in the current task. Codex host approval prompts still apply; this
workflow does not weaken them.

## Install, repair, and upgrade

After consent, run `../../scripts/Install-BimBridgeHost.ps1 -UserApproved`
relative to `SKILL.md`. Add `-Action Repair` only for repair. Upgrade uses the
normal `Install` action when the status is `needs_upgrade`.

For a published build, the script downloads one exact release, verifies its
SHA-256, and invokes the packaged installer. For a trusted development plugin,
it invokes the installer only from the manifest's explicit local source root.
It must not create a personal plugin or edit a personal marketplace. It
registers only the external local MCP named `bim-bridge-local`; the Codex plugin
remains the skill and bootstrap layer.

The Host installer deploys every detected compatible certified connector and
returns `skippedProducts` for installed versions whose exact runtime is not
certified by that release. A skipped product must not fail or roll back the
compatible products, and its existing BIM Bridge manifest must be removed
inside the same recoverable transaction so an incompatible connector cannot
remain loadable.

The status probe and Host installer share the same Autodesk discovery code.
They prefer a validated explicit override, then Windows installer registry
records, then standard Program Files paths. Normally no override is needed. If
an installation has incomplete registry data and the user supplies its exact
directory, rerun preflight with, for example,
`-ProductInstallPathOverrides @{'revit:2024'='E:\Revit2024\Revit 2024'}` and
pass the same argument to `Install-BimBridgeHost.ps1` after consent. Never infer
or create a path mapping; the directory must contain the expected product
executable and Autodesk API assembly.

When installation succeeds, tell the user to close and reopen Codex, Revit,
and AutoCAD, then start a new Codex task. In that new task, rerun the status
script and proceed only when it reports `healthy`.

## Uninstall

After consent, run
`../../scripts/Install-BimBridgeHost.ps1 -Action Uninstall -UserApproved`.
Host-only uninstall removes BIM Bridge connectors, providers, local MCP host files, the
`bim-bridge-local` registration, and installation state. It preserves the
public Codex plugin itself.

## Failure handling

- Report checksum mismatches without retrying another URL.
- If Autodesk is running, stop and ask the user to close it.
- If installation rolls back, report the original failure and that the prior
  installation was restored.
- Do not fall back to manual file deletion or a second installer automatically.
