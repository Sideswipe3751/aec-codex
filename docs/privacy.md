# AEC Codex privacy policy

Effective date: August 11, 2026

AEC Codex is open-source software that connects Codex to Autodesk AutoCAD and
Revit running on the same Windows computer. The AEC Codex project does not
operate a hosted MCP service, advertising service, analytics service, or user
account system.

## Data the project collects

AEC Codex itself does not collect or sell personal information and does not
send telemetry to the project maintainers. Connector discovery records,
authentication tokens, installation state, and provider configuration are
stored under the current Windows user's profile. Authentication tokens are
generated locally and are not included in diagnostic output.

When you ask Codex to inspect or change a drawing or model, relevant document
metadata, entity or element properties, selections, paths, and requested
operation results may be passed between the local Autodesk connector and your
Codex session. Your use of Codex and OpenAI services is governed separately by
the terms and privacy policy applicable to your OpenAI account.

## Network access

The installer downloads a version-pinned AEC Codex release from GitHub and
verifies its SHA-256 before execution. Local connectors bind only to loopback
addresses. Pinned third-party providers run locally; AEC Codex does not expose
them as a public internet service.

## Storage and deletion

AEC Codex stores per-user files in `%LOCALAPPDATA%\AEC Codex`, Autodesk's
per-user add-in folders under `%APPDATA%`, and a local Codex MCP registration.
The uninstall workflow removes these AEC Codex host components and the MCP
registration while preserving the public Codex plugin listing. Autodesk
documents changed at the user's request remain the user's responsibility.

## Contact

For privacy questions, open a private security report or maintainer contact
through the repository at <https://github.com/Sideswipe3751/aec-codex/security>.
