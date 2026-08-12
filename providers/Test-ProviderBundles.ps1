[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ArtifactsRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $ArtifactsRoot) { $ArtifactsRoot = Join-Path $SourceRoot 'artifacts\providers' }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-provider-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    $lock = Get-Content -LiteralPath (Join-Path $SourceRoot 'plugins\aec-codex\providers\providers.lock.json') -Raw | ConvertFrom-Json
    $revit = $lock.providers | Where-Object { $_.id -eq 'revit-community' }
    $autocad = $lock.providers | Where-Object { $_.id -eq 'autocad-pro' }
    $revitRoot = Join-Path $ArtifactsRoot ('revit-community\' + $revit.version + '\addin\revit_mcp_plugin')
    $registryPath = Join-Path $revitRoot 'Commands\commandRegistry.json'
    if (-not (Test-Path -LiteralPath $registryPath)) { throw 'Packaged Revit command registry is missing.' }
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    if (-not $registry.commands -or $registry.commands.Count -eq 0) { throw 'Packaged Revit command registry is empty.' }
    foreach ($command in $registry.commands) {
        if ($command.assemblyPath -ne 'RevitMCPCommandSet\{VERSION}\RevitMCPCommandSet.dll') {
            throw "Packaged Revit command has an invalid assembly path: $($command.commandName)"
        }
    }
    $revitCommandAssembly = Join-Path $revitRoot 'Commands\RevitMCPCommandSet\2024\RevitMCPCommandSet.dll'
    if (-not (Test-Path -LiteralPath $revitCommandAssembly)) { throw 'Packaged Revit 2024 command assembly is missing.' }
    $revitBundleRoot = Join-Path $ArtifactsRoot ('revit-community\' + $revit.version)
    $revitServer = Join-Path $revitBundleRoot 'server'
    $revitNpm = Join-Path $revitBundleRoot 'runtime\node\npm.cmd'
    $originalPath = $env:PATH
    try {
        $env:PATH = (Split-Path -Parent $revitNpm) + [IO.Path]::PathSeparator + $originalPath
        & $revitNpm audit --prefix $revitServer --omit=dev --audit-level=low --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Packaged Revit runtime dependencies failed npm audit.' }
    } finally {
        $env:PATH = $originalPath
    }
    $wheel = Get-ChildItem -LiteralPath (Join-Path $ArtifactsRoot ('autocad-pro\' + $autocad.version)) -Filter 'autocad_mcp_pro-*.whl' -File | Select-Object -First 1
    if (-not $wheel) { throw 'Packaged AutoCAD wheel is missing or has an invalid filename.' }
    & python (Join-Path $SourceRoot 'providers\Patch-AutoCADWheel.py') $wheel.FullName --verify
    if ($LASTEXITCODE -ne 0) { throw 'Packaged AutoCAD wheel is missing the AEC Codex COM fixes.' }
    & python -m venv (Join-Path $temporaryRoot 'venv')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create provider smoke-test environment.' }
    $testPython = Join-Path $temporaryRoot 'venv\Scripts\python.exe'
    & $testPython -m pip install --disable-pip-version-check --no-input ($wheel.FullName + '[com]')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to install packaged AutoCAD provider.' }
    $autocadCommand = Join-Path $temporaryRoot 'venv\Scripts\autocad-mcp.exe'
    $snapshot = Join-Path $temporaryRoot 'provider-schemas.json'
    & $testPython (Join-Path $SourceRoot 'tests\mcp\smoke_provider_artifacts.py') --artifacts $ArtifactsRoot --autocad-command $autocadCommand --output $snapshot
    if ($LASTEXITCODE -ne 0) { throw 'One or more packaged providers failed MCP initialization.' }
    # Windows PowerShell 5.1 ConvertFrom-Json rejects some valid, deeply nested
    # upstream schemas. Parse with the same Python runtime that produced the
    # snapshot and emit only the compact summary PowerShell needs.
    & $testPython (Join-Path $SourceRoot 'tests\mcp\summarize_provider_schemas.py') $snapshot
    if ($LASTEXITCODE -ne 0) { throw 'Unable to summarize provider schema snapshot.' }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe provider test cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
