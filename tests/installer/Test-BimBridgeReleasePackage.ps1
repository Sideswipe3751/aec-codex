[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ZipPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ZipPath = [IO.Path]::GetFullPath($ZipPath)
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'eng\AutodeskVersionMatrix.ps1')
$matrixPath = Join-Path $repoRoot 'eng\Autodesk.Versions.props'
$hashFile = $ZipPath + '.sha256'
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf) -or -not (Test-Path -LiteralPath $hashFile -PathType Leaf)) {
    throw 'Release archive or checksum file is missing.'
}
$expected = ((Get-Content -LiteralPath $hashFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "Release checksum mismatch: $actual" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $entries = @($archive.Entries)
    $blocked = @($entries | Where-Object { $_.FullName -match '(^|/)(\.env|\.npmrc|id_rsa|credentials)$|\.(pfx|p12|pem|key)$' })
    if ($blocked.Count -gt 0) { throw 'Release archive contains forbidden files.' }
    $mutablePython = @($entries | Where-Object { $_.FullName -match '(^|/)__pycache__(/|$)|\.pyc$' })
    if ($mutablePython.Count -gt 0) { throw 'Release archive contains mutable generated Python bytecode.' }
    $requiredEntries = @(
        'bim-bridge/installer/Install-BimBridge.ps1',
        'bim-bridge/plugins/bim-bridge/scripts/AutodeskProductDiscovery.ps1',
        'bim-bridge/runtime/python/python.exe'
    )
    foreach ($entry in @(Get-RevitMatrixEntries $matrixPath | Where-Object CertificationStatus -eq 'certified')) {
        foreach ($target in @($entry.CertifiedTargetFrameworks -split ';')) {
            $requiredEntries += "bim-bridge/src/BimBridge.Revit/bin/Release/$($entry.Include)/$target/$($entry.AssemblyName).dll"
            $requiredEntries += "bim-bridge/src/BimBridge.Revit/bin/Release/$($entry.Include)/$target/$($entry.ManifestName)"
        }
    }
    foreach ($entry in @(Get-AutoCADMatrixEntries $matrixPath | Where-Object CertificationStatus -eq 'certified')) {
        foreach ($target in @($entry.CertifiedTargetFrameworks -split ';')) {
            $requiredEntries += "bim-bridge/src/BimBridge.AutoCAD/bin/Release/$($entry.Include)/$target/$($entry.AssemblyName).dll"
        }
    }
    foreach ($required in $requiredEntries) {
        if ($entries.FullName -notcontains $required) { throw "Release archive is missing: $required" }
    }
} finally { $archive.Dispose() }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-package-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $testRoot
    $sourceRoot = Join-Path $testRoot 'bim-bridge'
    $embeddedManifest = Get-Content -LiteralPath (Join-Path $sourceRoot 'plugins\bim-bridge\release-manifest.json') -Raw | ConvertFrom-Json
    if ([bool]$embeddedManifest.published -or $embeddedManifest.releaseZipUri -or $embeddedManifest.sha256) {
        throw 'The Host archive contains a self-pinning public release manifest.'
    }
    $validation = (& (Join-Path $sourceRoot 'installer\Install-BimBridge.ps1') -SourceRoot $sourceRoot -SkipBuild -ValidateOnly) | ConvertFrom-Json
    if ($validation.status -ne 'validated' -or @($validation.autocad).Count -ne 4) {
        throw 'The extracted release package did not validate all installed AutoCAD versions.'
    }
    [ordered]@{ status='passed'; sha256=$actual; entries=$entries.Count } | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe package-test cleanup target: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
