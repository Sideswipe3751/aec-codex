[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$Version = '1.1.0-rc.3',
    [string]$OutputDirectory,
    [switch]$AllowUnpublished
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $SourceRoot 'artifacts\submission' }

function Copy-SubmissionPath([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Submission input is missing: $Source" }
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

$pluginRoot = Join-Path $SourceRoot 'plugins\aec-codex'
$pluginManifest = Get-Content -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
$releaseManifest = Get-Content -LiteralPath (Join-Path $pluginRoot 'release-manifest.json') -Raw | ConvertFrom-Json
if ([string]$pluginManifest.version -ne $Version -or [string]$releaseManifest.version -ne $Version) {
    throw "Plugin, release, and submission versions must all equal $Version."
}
if (-not $AllowUnpublished) {
    if (-not [bool]$releaseManifest.published) { throw "AEC Codex $Version is not published." }
    if ([string]$releaseManifest.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'The published release SHA-256 is missing.' }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-submission-' + [Guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $temporaryRoot 'aec-codex'
New-Item -ItemType Directory -Force -Path $stageRoot,$OutputDirectory | Out-Null
try {
    $sourceSkill = Join-Path $pluginRoot 'skills\aec-codex'
    Copy-SubmissionPath (Join-Path $sourceSkill 'SKILL.md') (Join-Path $stageRoot 'SKILL.md')
    Copy-SubmissionPath (Join-Path $sourceSkill 'references') (Join-Path $stageRoot 'references')
    Copy-SubmissionPath (Join-Path $sourceSkill 'agents') (Join-Path $stageRoot 'agents')
    Copy-SubmissionPath (Join-Path $pluginRoot 'scripts\Get-AecCodexHostStatus.ps1') (Join-Path $stageRoot 'scripts\Get-AecCodexHostStatus.ps1')
    Copy-SubmissionPath (Join-Path $pluginRoot 'scripts\Install-AecCodexHost.ps1') (Join-Path $stageRoot 'scripts\Install-AecCodexHost.ps1')
    Copy-SubmissionPath (Join-Path $pluginRoot 'release-manifest.json') (Join-Path $stageRoot 'release-manifest.json')
    Copy-SubmissionPath (Join-Path $SourceRoot 'LICENSE') (Join-Path $stageRoot 'LICENSE')

    $skillText = Get-Content -LiteralPath (Join-Path $stageRoot 'SKILL.md') -Raw
    if ($skillText -notmatch '(?s)^---\s*\r?\nname:\s*aec-codex\s*\r?\ndescription:') {
        throw 'Public skill front matter is invalid.'
    }
    $forbiddenFiles = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Force | Where-Object {
        $_.Name -in @('.mcp.json', 'marketplace.json') -or $_.Extension -match '^\.(exe|dll|whl|pfx|p12|pem|key)$'
    })
    if ($forbiddenFiles.Count -gt 0) {
        throw ('Public skill bundle contains forbidden files: ' + (($forbiddenFiles | Select-Object -ExpandProperty FullName) -join ', '))
    }
    $forbiddenText = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse | Select-String -Pattern '\|\s*(Invoke-Expression|iex)\b|--ref\s+latest|BEGIN (RSA |OPENSSH )?PRIVATE KEY' -CaseSensitive:$false)
    if ($forbiddenText.Count -gt 0) {
        throw ('Public skill bundle contains a forbidden instruction: ' + $forbiddenText[0].Path)
    }

    $zipName = "aec-codex-public-skill-$Version.zip"
    $zipPath = Join-Path $OutputDirectory $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipPath + '.sha256', ($hash + '  ' + $zipName + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    Write-Host "Submission bundle: $zipPath"
    Write-Host "SHA-256: $hash"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe submission cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
