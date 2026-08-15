# Repository instructions

## Architecture gate

Before changing code, build logic, tests, Autodesk manifests, provider routing,
packaging, or installer behavior, read `docs/architecture.md` in full.

Treat that document as the repository's architecture contract:

- preserve its architectural invariants;
- keep the BIM Bridge Runtime independent from Codex, DeepSeek Harness, and other
  agent SDKs; agent-specific behavior belongs in thin adapters;
- preserve the single versioned BIM Bridge Contract and capability/provider/policy
  boundaries rather than adding transport-specific domain models;
- use its shared-core, runtime-family, compatibility-layer, and version-matrix
  boundaries for Autodesk version work;
- do not add a new year by copying an existing full adapter or hard-coding a
  second version list;
- keep the release installer frozen after the Revit 2024-2027 certification
  gate until the user explicitly starts the packaging phase;
- update `docs/architecture.md` in the same change whenever an implementation
  decision makes it incomplete or inaccurate.

In the final report for a code change, state whether the architecture contract
was preserved or updated.
