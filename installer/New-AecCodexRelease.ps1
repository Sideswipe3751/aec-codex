[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$Version = '1.1.0',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $SourceRoot 'artifacts\release' }

function Copy-ReleasePath([string]$RelativePath, [string]$StageRoot) {
    $source = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source)) { throw "Release input is missing: $source" }
    $destination = Join-Path $StageRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

& dotnet build (Join-Path $SourceRoot 'AEC.Codex.slnx') -c Release
if ($LASTEXITCODE -ne 0) { throw 'AEC Codex release build failed.' }
$providerArtifacts = Join-Path $SourceRoot 'artifacts\providers'
if (-not (Test-Path -LiteralPath (Join-Path $providerArtifacts 'build-manifest.json'))) {
    & (Join-Path $SourceRoot 'providers\Build-Providers.ps1') -SourceRoot $SourceRoot -OutputRoot $providerArtifacts
}
if (-not (Test-Path -LiteralPath (Join-Path $providerArtifacts 'build-manifest.json'))) {
    throw 'Verified provider bundles are required for a release.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-release-' + [Guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $temporaryRoot 'aec-codex'
New-Item -ItemType Directory -Force -Path $stageRoot,$OutputDirectory | Out-Null
try {
    foreach ($path in @(
        'README.md',
        'THIRD_PARTY_NOTICES.md',
        'installer\Install-AecCodex.ps1',
        'installer\Install-AecProviders.ps1',
        'plugins\aec-codex',
        'providers',
        'src\Aec.Codex.Revit2024\Aec.Codex.Revit2024.addin',
        'src\Aec.Codex.Revit2024\bin\Release\net48',
        'src\Aec.Codex.AutoCAD2024\PackageContents.xml',
        'src\Aec.Codex.AutoCAD2024\bin\Release\net48',
        'artifacts\providers'
    )) { Copy-ReleasePath $path $stageRoot }

    $zipName = "aec-codex-$Version-win-x64.zip"
    $zipPath = Join-Path $OutputDirectory $zipName
    if (Test-Path -LiteralPath $zipPath) { throw "Release output already exists: $zipPath" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stageRoot,
        $zipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipPath + '.sha256', ($hash + '  ' + $zipName + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    Write-Host "Release: $zipPath"
    Write-Host "SHA-256: $hash"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe release cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
