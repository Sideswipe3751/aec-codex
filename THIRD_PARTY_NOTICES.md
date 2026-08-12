# Third-party notices

AEC Codex installs and interoperates with third-party providers. The
providers remain separate versioned components; their licenses and copyright
notices are included in each installed provider directory.

## mcp-servers-for-revit

- Source: https://github.com/mcp-servers-for-revit/mcp-servers-for-revit
- Pinned release: v1.0.0
- License: MIT
- Copyright: the mcp-servers-for-revit contributors

## AutoCAD MCP Pro

- Source: https://github.com/U-C4N/Autocad-MCP
- Pinned release: v1.5.1
- License: MIT
- Copyright: Umutcan Edizsalan and contributors

AEC Codex itself is not endorsed by Autodesk or by either upstream project.

## Node.js runtime

- Source: https://github.com/nodejs/node
- Pinned release: v22.23.2 (Windows x64)
- License: MIT
- Copyright: Node.js contributors

The release build uses npm to assemble the provider, but the shipped runtime is
trimmed to Node.js and its license. Server dependencies and their license
metadata remain in the provider bundle.

## Python runtime and packages

- Source: https://www.python.org/
- Pinned runtime: CPython 3.12.10 embeddable package (Windows x64)
- License: Python Software Foundation License
- Copyright: Python Software Foundation and contributors

The private runtime contains the pinned AutoCAD provider and its Python
dependencies. Package metadata and license files are preserved under
`Lib/site-packages`; CPython's `LICENSE.txt` is preserved at the runtime root.

## AEC Codex modifications

AEC Codex applies documented compatibility and security patches while building
the pinned providers. The upstream components remain under their original MIT
licenses, and their copyright and license notices are preserved in source and
binary distributions.
