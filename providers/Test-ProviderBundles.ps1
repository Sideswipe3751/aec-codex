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
    $autocad = $lock.providers | Where-Object { $_.id -eq 'autocad-pro' }
    $wheel = Get-ChildItem -LiteralPath (Join-Path $ArtifactsRoot ('autocad-pro\' + $autocad.version)) -Filter 'autocad_mcp_pro-*.whl' -File | Select-Object -First 1
    if (-not $wheel) { throw 'Packaged AutoCAD wheel is missing or has an invalid filename.' }
    & python -m venv (Join-Path $temporaryRoot 'venv')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create provider smoke-test environment.' }
    $testPython = Join-Path $temporaryRoot 'venv\Scripts\python.exe'
    & $testPython -m pip install --disable-pip-version-check --no-input ($wheel.FullName + '[com]')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to install packaged AutoCAD provider.' }
    $autocadCommand = Join-Path $temporaryRoot 'venv\Scripts\autocad-mcp.exe'
    $snapshot = Join-Path $temporaryRoot 'provider-schemas.json'
    & $testPython (Join-Path $SourceRoot 'tests\mcp\smoke_provider_artifacts.py') --artifacts $ArtifactsRoot --autocad-command $autocadCommand --output $snapshot
    if ($LASTEXITCODE -ne 0) { throw 'One or more packaged providers failed MCP initialization.' }
    $schema = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
    foreach ($provider in $schema.providers) {
        Write-Host ("Verified {0} {1}: {2} allowed structured tools" -f $provider.id,$provider.version,$provider.tools.Count)
    }
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
