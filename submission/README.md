# Public Plugins Directory submission

This directory contains the materials for submitting BIM Bridge as a public
Skills-only plugin. The public skill performs a read-only first-run check,
explains the exact native changes, asks for explicit approval, downloads one
version-pinned host release, verifies SHA-256, and invokes the transactional
current-user installer. The installed host currently registers the legacy
`aec-codex-local` identifier as an
external local MCP server.

The public submission intentionally contains no executable connector binaries,
Python runtime, credentials, remote MCP URL, or personal marketplace file.
Those components are delivered only by the approved, checksum-pinned GitHub
release after user consent.

Build the upload bundle with:

```powershell
& .\installer\New-AecCodexSubmission.ps1 -Version '1.1.0-rc.3'
```

Before uploading, complete the following owner-controlled actions:

1. Use `branding/official/bim-bridge-logo-transparent.png` as the owner-selected
   listing logo. Its four exterior corners are transparent; the white source
   border must never be uploaded.
2. Publish the exact rc.3 host ZIP and set its final SHA-256 and `published`
   flag in `plugins/aec-codex/release-manifest.json`.
3. Confirm the verified OpenAI developer or business identity that will own
   the listing and that the submitter has Apps Management Write permission.
4. Review the privacy policy, terms, support URL, listing copy, and test cases.
5. Upload the generated skill ZIP in the developer platform submission flow.
6. After approval, publish the approved version from the dashboard.

Review duration has no published service-level guarantee and varies with the
submission and follow-up questions. Plan for a variable review rather than a
fixed number of days.
