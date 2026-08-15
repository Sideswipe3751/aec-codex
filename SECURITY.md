# Security policy

## Supported versions

Only the latest published release candidate receives security fixes. Autodesk
version support is limited to the matrix in the project README.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature from the repository's
**Security** tab. Do not disclose suspected vulnerabilities in a public issue,
discussion, pull request, screenshot, or log attachment.

Include:

- the affected BIM Bridge version and commit;
- the affected Autodesk and Codex versions;
- reproduction steps using non-sensitive test data;
- impact and expected security boundary;
- any proposed mitigation.

Remove bearer tokens, connector descriptors, personal paths, Autodesk document
contents, and unrelated application logs before submitting evidence.

## Security boundaries

BIM Bridge connectors are designed for loopback-only access and authenticate
requests with per-process bearer tokens stored in current-user descriptor
files. Writes remain subject to Codex approval and Autodesk transaction rules.
Report any bypass of these boundaries privately.
