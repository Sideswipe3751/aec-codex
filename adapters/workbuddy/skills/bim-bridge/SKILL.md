---
name: bim-bridge
description: Bootstrap, diagnose, inspect, draw, model, reconstruct from drawings, change, and verify local Autodesk Revit and AutoCAD sessions through BIM Bridge. Use for BIM Bridge setup and health checks, Revit or AutoCAD reads and writes, PDF or image drawing-to-model work, and structured plus visual validation of completed Autodesk work.
---

# BIM Bridge for WorkBuddy

Use the configured `bim-bridge` MCP server as the only route into Revit or
AutoCAD. Existing `aec_*` MCP tool names are compatibility identifiers shared
with other adapters; do not rename or wrap them into a WorkBuddy-only contract.

## First activation gate

At the first activation in every WorkBuddy task concerning BIM Bridge, Revit,
or AutoCAD, run:

```powershell
& "${CODEBUDDY_PLUGIN_ROOT}\skills\bim-bridge\scripts\Get-BimBridgeWorkBuddyStatus.ps1"
```

When the Skill is loaded outside a managed plugin, resolve `scripts` relative
to this `SKILL.md` instead. The command is read-only. Run it again only after
the Host, plugin, MCP configuration, WorkBuddy version, or Autodesk process
state changes.

- Continue only when `status` is `healthy`.
- For `workbuddy_not_found`, explain that Tencent WorkBuddy is required.
- For `not_installed` or `needs_repair`, read `references/setup.md`, report the
  exact evidence, and stop. This experimental Skill does not mutate the Host.
- Installing or importing this Skill is not permission to modify Autodesk,
  `%LOCALAPPDATA%\BIM Bridge`, or WorkBuddy user configuration.

## MCP workflow

1. Probe provider and capability discovery before choosing an operation.
2. Inspect the selected tool schema instead of guessing parameters.
3. Read document, selection, and affected objects before a write.
4. For a write, use the provider's dry-run or preview mode first when available.
5. Execute only the user-authorized bounded change against an exact application,
   process, and document target.
6. Never fall back to arbitrary Autodesk code after a structured write is
   denied, invalid, or may have started mutation.
7. Read back identifiers, geometry, properties, counts, and relationships that
   define success.
8. When appearance or spatial coordination matters, use the discovered focused
   view-capture capability after structured verification.
9. For drawing, modeling, creation, or layout work, read
   `references/drawing-quality.md` and run its correction and completion loop.
10. For PDF, image, scan, CAD, plan, elevation, or section reconstruction, also
    read `references/model-reconstruction.md`. Do not downgrade form-defining
    geometry to schematic massing unless the user explicitly requests that
    lower-fidelity deliverable.

## Safety

- WorkBuddy is the single user-facing approval layer. Do not add a second prompt
  inside Autodesk or attempt to bypass WorkBuddy permission controls.
- Dynamic-code reads and writes have ambient host authority and remain critical
  capabilities even when the intended operation sounds harmless.
- Do not switch to another provider or Autodesk instance after mutation may
  have started.
- Stop on target, authentication, transaction, or version mismatch.
- Do not claim completion until required readback and visual checks pass.
- Do not stop between ordinary modeling stages to ask whether to continue when
  the user's request already authorizes the complete bounded workflow. Stop
  only for a genuine target, authority, source, safety, or technical blocker.

For setup and local debugging, read `references/setup.md`.
