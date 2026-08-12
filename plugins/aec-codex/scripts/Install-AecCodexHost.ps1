[CmdletBinding()]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$ManifestPath,
    [switch]$UserApproved,
    [switch]$SkipProviders
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ProgressPreference = 'SilentlyContinue'

function Write-Result([hashtable]$Value) {
    $Value | ConvertTo-Json -Depth 8
}

function Copy-Release([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return
    }
    Invoke-WebRequest -Uri ([uri]$Source) -OutFile $Destination -UseBasicParsing
}

if (-not $UserApproved) {
    throw 'AEC Codex host changes require explicit user approval in the current task. Run the read-only status check first.'
}

$pluginRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $pluginRoot 'release-manifest.json' }
$localRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$statePath = Join-Path $localRoot 'AEC Codex\install-state.json'

if ($Action -eq 'Uninstall') {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-Result ([ordered]@{ status='not_installed'; action='Uninstall'; changed=$false })
        return
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $uninstallerProperty = $state.PSObject.Properties['uninstaller']
    if (-not $uninstallerProperty -or -not $uninstallerProperty.Value -or -not (Test-Path -LiteralPath $uninstallerProperty.Value -PathType Leaf)) {
        throw 'The installed AEC Codex uninstaller is missing. Run Repair before uninstalling.'
    }
    $uninstaller = [string]$uninstallerProperty.Value
    $maintenanceRoot = Split-Path -Parent (Split-Path -Parent $uninstaller)
    & $uninstaller -Action Uninstall -InstallMode HostOnly -SourceRoot $maintenanceRoot -Confirm:$false
    Write-Result ([ordered]@{ status='succeeded'; action='Uninstall'; changed=$true; pluginPreserved=$true })
    return
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Release manifest is missing: $ManifestPath" }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) { throw "Unsupported release manifest schema: $($manifest.schemaVersion)" }

$source = [string]$manifest.releaseZipUri
$expectedHash = if ($manifest.sha256) { [string]$manifest.sha256 } else { $null }
if (-not [bool]$manifest.published) {
    throw "AEC Codex $($manifest.version) has not been published. The host installer cannot run until its release hash is finalized."
}
if (-not $source) { throw 'The release ZIP URI is missing.' }
if (-not $expectedHash -or $expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'The release SHA-256 is missing or invalid.' }

$statusScript = Join-Path $PSScriptRoot 'Get-AecCodexHostStatus.ps1'
$preflight = (& $statusScript -ManifestPath $ManifestPath) | ConvertFrom-Json
if ($preflight.status -eq 'healthy' -and $Action -eq 'Install') {
    Write-Result ([ordered]@{
        status='healthy'; action='Install'; version=[string]$manifest.version
        changed=$false; restartRequired=$false
    })
    return
}
if ($preflight.status -eq 'restart_required' -and $Action -eq 'Install') {
    Write-Result ([ordered]@{
        status='restart_required'; action='Install'; version=[string]$manifest.version
        changed=$false; restartRequired=$true
    })
    return
}
if (@($preflight.prerequisiteIssues).Count -gt 0) {
    throw ('AEC Codex prerequisites are not satisfied: ' + (@($preflight.prerequisiteIssues) -join ' '))
}
if (@($preflight.runningAutodesk).Count -gt 0) {
    throw 'Close Revit and AutoCAD before installing or repairing AEC Codex.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-host-' + [Guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $temporaryRoot 'release.zip'
$extractPath = Join-Path $temporaryRoot 'release'
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    Copy-Release $source $zipPath
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
        throw "Release checksum mismatch. Expected $expectedHash, received $actualHash."
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    $installer = Get-ChildItem -LiteralPath $extractPath -Filter Install-AecCodex.ps1 -File -Recurse | Select-Object -First 1
    if (-not $installer) { throw 'The verified release does not contain Install-AecCodex.ps1.' }
    $sourceRoot = Split-Path -Parent $installer.DirectoryName
    $packagedManifest = Join-Path $sourceRoot 'plugins\aec-codex\.codex-plugin\plugin.json'
    if (-not (Test-Path -LiteralPath $packagedManifest -PathType Leaf)) { throw 'The verified release has no AEC Codex plugin manifest.' }
    $packagedVersion = (Get-Content -LiteralPath $packagedManifest -Raw | ConvertFrom-Json).version
    if ([string]$packagedVersion -ne [string]$manifest.version) {
        throw "Release version mismatch. Expected $($manifest.version), received $packagedVersion."
    }

    $arguments = @{
        Action = $Action
        InstallMode = 'HostOnly'
        SourceRoot = $sourceRoot
        SkipBuild = $true
        Confirm = $false
    }
    if ($SkipProviders) { $arguments.SkipProviders = $true }
    & $installer.FullName @arguments
    Write-Result ([ordered]@{
        status='succeeded'; action=$Action; version=[string]$manifest.version
        changed=$true; restartRequired=$true
    })
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe bootstrap cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
