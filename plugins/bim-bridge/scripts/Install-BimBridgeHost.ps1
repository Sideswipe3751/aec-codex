[CmdletBinding()]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$ManifestPath,
    [string]$LocalSourceRoot,
    [switch]$UserApproved,
    [switch]$MigrateLegacy
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ProgressPreference = 'SilentlyContinue'

function Write-Result([hashtable]$Value) { $Value | ConvertTo-Json -Depth 10 }

if (-not $UserApproved) {
    throw 'BIM Bridge host changes require explicit approval in the current task. Run the read-only status check first.'
}

$pluginRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $pluginRoot 'release-manifest.json' }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Release manifest is missing: $ManifestPath" }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 2) { throw "Unsupported BIM Bridge release manifest schema: $($manifest.schemaVersion)" }
if (-not $LocalSourceRoot -and $manifest.PSObject.Properties['developmentSourceRoot'] -and $manifest.developmentSourceRoot) {
    $LocalSourceRoot = [string]$manifest.developmentSourceRoot
}

$statusScript = Join-Path $PSScriptRoot 'Get-BimBridgeHostStatus.ps1'
$preflight = (& $statusScript -ManifestPath $ManifestPath) | ConvertFrom-Json
if (@($preflight.prerequisiteIssues).Count -gt 0) {
    throw ('BIM Bridge prerequisites are not satisfied: ' + (@($preflight.prerequisiteIssues) -join ' '))
}
if (@($preflight.runningAutodesk).Count -gt 0) {
    throw 'Close every Revit and AutoCAD session before installing, repairing, or uninstalling BIM Bridge.'
}

if ($LocalSourceRoot) {
    $installer = Join-Path ([IO.Path]::GetFullPath($LocalSourceRoot)) 'installer\Install-BimBridge.ps1'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Local BIM Bridge installer is missing: $installer" }
    $arguments = @{ Action=$Action; SourceRoot=[IO.Path]::GetFullPath($LocalSourceRoot); Confirm=$false }
    if ($MigrateLegacy) { $arguments.MigrateLegacy = $true }
    & $installer @arguments
    return
}

if (-not [bool]$manifest.published) {
    throw "BIM Bridge $($manifest.version) is a local development build. A trusted LocalSourceRoot is required."
}
if (-not $manifest.releaseZipUri -or [string]$manifest.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw 'Published BIM Bridge release metadata is incomplete.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-host-' + [Guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $temporaryRoot 'release.zip'
$extractPath = Join-Path $temporaryRoot 'release'
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    Invoke-WebRequest -Uri ([uri]$manifest.releaseZipUri) -OutFile $zipPath -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actualHash -ne ([string]$manifest.sha256).ToUpperInvariant()) {
        throw "Release checksum mismatch. Expected $($manifest.sha256), received $actualHash."
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    $installer = Get-ChildItem -LiteralPath $extractPath -Filter Install-BimBridge.ps1 -File -Recurse | Select-Object -First 1
    if (-not $installer) { throw 'The verified release does not contain Install-BimBridge.ps1.' }
    $sourceRoot = Split-Path -Parent $installer.DirectoryName
    $arguments = @{ Action=$Action; SourceRoot=$sourceRoot; SkipBuild=$true; Confirm=$false }
    if ($MigrateLegacy) { $arguments.MigrateLegacy = $true }
    & $installer.FullName @arguments
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe cleanup target: $resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
