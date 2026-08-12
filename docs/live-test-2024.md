# Revit and AutoCAD 2024 live acceptance

Use disposable files. Save a copy before write tests. Revit and AutoCAD must be
closed during installation and restarted afterward; Codex must use a new task
so the updated plugin and provider configuration are loaded.

## Installation gate

1. Run `installer\Install-AecCodex.ps1` from a normal PowerShell session.
2. Confirm both applications start without add-in load errors.
3. In Revit, click **Revit MCP Switch** and confirm the server-open message.
4. In a new Codex task, ask: `检查 Revit 和 AutoCAD 结构化 provider 是否就绪，先不要修改任何文件。`
5. Acceptance: `revit-community` reports 25 allowed tools and `autocad-pro`
   reports 47 tools. Both local AEC Codex connector instances are discoverable.

## Revit 2024

Open a disposable project with one level and an active floor plan.

1. Read active view, selected elements, and available wall types using
   structured tools.
2. Preview creation of a 3000 mm wall. Acceptance: `status=previewed` or an
   upstream native preview, and the model does not change.
3. Execute the wall creation, then read it back by element ID.
4. Trigger a deliberately invalid structured write. Acceptance: no partial
   element remains and the provider returns an error.
5. Request a read not covered by structured tools and verify the dynamic C#
   fallback reads it.
6. In a second disposable copy, trigger a fallback write that throws after
   creating an element. Acceptance: `rolledBack=true` and no element remains.

## AutoCAD 2024

Open a disposable blank drawing.

1. Read drawing information, layers, and current entities using structured
   tools.
2. Preview creation of a 1000-unit line. Acceptance: the drawing does not
   change.
3. Execute line creation, read it back by handle, then move it and verify the
   new coordinates.
4. Exercise `transaction_begin`, a create operation, and
   `transaction_rollback`. Acceptance: the created entity does not remain.
5. Request an unsupported read through the dynamic C# fallback.
6. Trigger a fallback write that throws after appending an entity. Acceptance:
   `rolledBack=true` and no entity remains.

## Safety and restart checks

- `send_code_to_revit`, AutoCAD command execution, and LISP execution must not
  appear in provider search results.
- A provider write passed to the read gateway must be refused.
- Revit's community TCP listener must bind only to loopback and reject a
  missing/incorrect `_aecToken`.
- Close and reopen each Autodesk application once. Instance descriptors from
  exited processes must disappear and new instances must be routed correctly.
- Run `providers\Update-AecProviders.ps1 -Action Snapshot` after both providers
  are live. A later snapshot must report added, removed, and changed schemas.
