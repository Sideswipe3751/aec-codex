# Zexus bridge audit

Reference branch: `Sideswipe3751/zexus`, `codex/revit-codex-bridge`, commit
`71173132cc0f6ce07c8b0374b81692d9fa36c40c`.

## Reuse

- Dependency-free Python STDIO MCP implementation and protocol tests.
- Loopback-only HTTP bridge.
- Per-session bearer token and ephemeral connection descriptor.
- Request store, status lifecycle, watchdog, timeout, and audit log.
- Revit `ExternalEvent` dispatch and UI-thread execution.
- Read/write signal checks and dangerous-code scanning as defense in depth.
- Revit 2024 compatibility helpers and transaction result handling.

## Refactor

- Generalize Revit-specific bridge names into application-neutral contracts.
- Replace the single token file with one descriptor per running process.
- Split read and write MCP tools and add accurate tool annotations.
- Add capability negotiation, product/version metadata, and explicit instance
  routing.
- Separate shared bridge code from Revit and AutoCAD API adapters.

## Do not carry forward

- `BridgeApprovalSettings` and its session mode.
- `WriteConfirmationDialog`.
- Revit ribbon controls that change approval mode.
- Coupling to Zexus chat UI, LLM providers, or Zexus configuration.
