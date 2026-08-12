# Contributing to AEC Codex

Thank you for helping improve AEC Codex. The project is an early release
candidate, so reproducible reports and narrowly scoped changes are especially
valuable.

## Before opening an issue

- Search existing issues and the release notes.
- Remove document contents, paths, usernames, tokens, and other sensitive data
  from logs and screenshots.
- Include Windows, Codex, Autodesk, Python, and AEC Codex versions.
- Reproduce write failures in a disposable drawing or model.

Security vulnerabilities must be reported privately according to
[SECURITY.md](SECURITY.md).

## Development workflow

1. Fork the repository and create a focused branch.
2. Keep Autodesk-version-specific code in its matching adapter project.
3. Preserve loopback-only transport, bearer-token authentication, bounded
   execution, and the single Codex approval layer.
4. Add or update tests for behavioral changes.
5. Run the relevant automated tests and describe any required live Autodesk
   validation in the pull request.

Do not commit Autodesk documents, local connector descriptors, provider build
artifacts, tokens, credentials, or proprietary Autodesk assemblies.

## Developer Certificate of Origin

Contributions use the Developer Certificate of Origin 1.1. Sign off each commit
to certify that you have the right to submit it under this project's license:

```text
Signed-off-by: Your Name <your-email@example.com>
```

Git can add the sign-off automatically:

```powershell
git commit -s
```

See https://developercertificate.org/ for the full certificate text.

## License

Unless explicitly stated otherwise, contributions intentionally submitted to
AEC Codex are licensed under Apache-2.0. Third-party components retain their
existing licenses and notices.
