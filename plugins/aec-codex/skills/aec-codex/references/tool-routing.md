# Tool routing

## Prefer structured tools

Choose the narrowest tool that can complete the request. Structured tools make
intent, validation, idempotency, and approval behavior clearer than arbitrary
code. Query before mutation and return stable element/entity identifiers.

## Revit fallback code

Run through the Revit connector's `ExternalEvent` context. Use the provided
`UIApplication`, active `UIDocument`, and `Document`. Do not create another UI
thread. Put related writes in a `Transaction` or `TransactionGroup`, handle
failure, and avoid relying on localized display strings when stable IDs exist.

## AutoCAD fallback code

Run through the connector's supported command context. Lock the target document
when required, use the target database transaction manager, open objects in the
least permissive mode, and commit only after all requested changes succeed.

## Cross-version behavior

Use connector capabilities rather than guessing from a year number. Do not use
a 2027-only API in a 2024 session. If a capability is absent, explain the
version limitation or choose a documented compatibility path.
