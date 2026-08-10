# Connector protocol

Each running connector writes one JSON descriptor to
`%APPDATA%\AEC Codex\instances\<instance-id>.json`. The descriptor follows
`protocol/instance.schema.json` in the repository.

The MCP host accepts only `http://127.0.0.1:<port>` URLs and sends the descriptor
token as `Authorization: Bearer <token>`. A connector must atomically replace
its descriptor when document metadata changes and remove it during clean
shutdown. The MCP host ignores malformed or stale descriptors.

Protocol v1 connector endpoints:

- `GET /v1/info`: application, version, document, and capabilities.
- `GET /v1/selection`: current selection summary.
- `POST /v1/execute`: enqueue a bounded read or write operation.
- `GET /v1/requests/<request-id>`: inspect request state and result.
- `POST /v1/requests/<request-id>/cancel`: request cancellation.

Terminal request states are `succeeded`, `failed`, `rejected`, `expired`, and
`cancelled`. Non-terminal states are `queued`, `waiting_for_application`, and
`running`.
