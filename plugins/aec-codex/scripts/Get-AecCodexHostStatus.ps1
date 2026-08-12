[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$StateRoot,
    [string]$RoamingRoot,
    [string]$LocalRoot,
    [string]$ProgramFilesRoot,
    [string]$ProgramFilesX86Root,
    [string]$CodexStartedAtUtc
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-PythonStatus([version]$MinimumVersion) {
    $command = Get-Command python -ErrorAction SilentlyContinue
    if (-not $command) {
        return [ordered]@{ found=$false; command=$null; version=$null; supported=$false }
    }
    try {
        $value = & $command.Source -c 'import sys;print(sys.version_info.major,sys.version_info.minor,sys.version_info.micro,sep=chr(46))' 2>$null
        $parsed = [version]$value
        return [ordered]@{
            found=$true; command=$command.Source; version=$parsed.ToString(); supported=($parsed -ge $MinimumVersion)
        }
    } catch {
        return [ordered]@{ found=$true; command=$command.Source; version=$null; supported=$false }
    }
}

function Test-ProductPath([string[]]$Roots, [string]$RelativePath) {
    foreach ($root in $Roots) {
        if ($root -and (Test-Path -LiteralPath (Join-Path $root $RelativePath))) { return $true }
    }
    return $false
}

if (-not $ManifestPath) { $ManifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'release-manifest.json' }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Release manifest is missing: $ManifestPath" }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) { throw "Unsupported release manifest schema: $($manifest.schemaVersion)" }

if (-not $RoamingRoot) { $RoamingRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData) }
if (-not $LocalRoot) { $LocalRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) }
if (-not $StateRoot) { $StateRoot = Join-Path $LocalRoot 'AEC Codex' }
if (-not $ProgramFilesRoot) { $ProgramFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles) }
if (-not $ProgramFilesX86Root) { $ProgramFilesX86Root = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86) }

$minimumPython = [version]$manifest.minimumPythonVersion
$python = Get-PythonStatus $minimumPython
$platformSupported = ($env:OS -eq 'Windows_NT' -and [Environment]::Is64BitOperatingSystem)
$prerequisiteIssues = New-Object System.Collections.ArrayList
if (-not $platformSupported) { [void]$prerequisiteIssues.Add('AEC Codex rc.2 requires 64-bit Windows.') }
if (-not $python.supported) { [void]$prerequisiteIssues.Add("Python $minimumPython or newer is required by this release candidate.") }

$programRoots = @($ProgramFilesRoot, $ProgramFilesX86Root)
$products = [ordered]@{
    autocad = @(
        [ordered]@{ version='2024'; installed=(Test-ProductPath $programRoots 'Autodesk\AutoCAD 2024') }
    )
    revit = @(
        [ordered]@{ version='2024'; installed=(Test-ProductPath $programRoots 'Autodesk\Revit 2024') }
    )
}

$running = @()
foreach ($process in @(Get-Process -Name Revit,acad -ErrorAction SilentlyContinue)) {
    $running += [ordered]@{ name=$process.ProcessName; processId=$process.Id }
}

$statePath = Join-Path $StateRoot 'install-state.json'
$state = $null
$stateError = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    catch { $stateError = $_.Exception.Message }
}

$missingFiles = New-Object System.Collections.ArrayList
$changedFiles = New-Object System.Collections.ArrayList
$recordedFiles = Get-PropertyValue $state 'files'
if ($recordedFiles) {
    foreach ($file in @($recordedFiles)) {
        if (-not $file.path -or -not (Test-Path -LiteralPath $file.path -PathType Leaf)) {
            [void]$missingFiles.Add([string]$file.path)
            continue
        }
        if ($file.sha256) {
            try {
                if ((Get-Sha256 $file.path) -ne ([string]$file.sha256).ToLowerInvariant()) {
                    [void]$changedFiles.Add([string]$file.path)
                }
            } catch { [void]$changedFiles.Add([string]$file.path) }
        }
    }
}

$knownFilesExist = @(@(
        (Join-Path $RoamingRoot 'Autodesk\Revit\Addins\2024\AEC.Codex.addin'),
        (Join-Path $RoamingRoot 'Autodesk\ApplicationPlugins\AEC Codex.bundle\PackageContents.xml'),
        (Join-Path $StateRoot 'providers\active.json')
    ) | Where-Object { Test-Path -LiteralPath $_ })

$restartRequired = $false
$stateRestartRequired = Get-PropertyValue $state 'restartRequired'
$stateInstalledAtUtc = Get-PropertyValue $state 'installedAtUtc'
if ($state -and $stateRestartRequired -and $stateInstalledAtUtc) {
    $installedAt = [datetime]::Parse([string]$stateInstalledAtUtc).ToUniversalTime()
    $codexStart = $null
    if ($CodexStartedAtUtc) {
        $codexStart = [datetime]::Parse($CodexStartedAtUtc).ToUniversalTime()
    } else {
        $codexProcesses = @(Get-Process -Name Codex,ChatGPT -ErrorAction SilentlyContinue)
        foreach ($process in $codexProcesses) {
            try {
                $started = $process.StartTime.ToUniversalTime()
                if (-not $codexStart -or $started -lt $codexStart) { $codexStart = $started }
            } catch { }
        }
    }
    if ($codexStart -and $codexStart -lt $installedAt) { $restartRequired = $true }
}

$status = 'healthy'
$recommendedAction = 'none'
if (-not $state) {
    if ($stateError -or $knownFilesExist.Count -gt 0) { $status = 'needs_repair'; $recommendedAction = 'repair' }
    elseif ($prerequisiteIssues.Count -gt 0) { $status = 'needs_prerequisite'; $recommendedAction = 'install_prerequisite' }
    else { $status = 'not_installed'; $recommendedAction = 'install' }
} elseif ($stateError -or $missingFiles.Count -gt 0 -or $changedFiles.Count -gt 0) {
    $status = 'needs_repair'; $recommendedAction = 'repair'
} elseif ([string](Get-PropertyValue $state 'version') -ne [string]$manifest.version) {
    $status = 'needs_upgrade'; $recommendedAction = 'upgrade'
} elseif ($prerequisiteIssues.Count -gt 0) {
    $status = 'needs_prerequisite'; $recommendedAction = 'install_prerequisite'
} elseif ($restartRequired) {
    $status = 'restart_required'; $recommendedAction = 'restart'
}

[ordered]@{
    schemaVersion = 1
    status = $status
    recommendedAction = $recommendedAction
    targetVersion = [string]$manifest.version
    releasePublished = [bool]$manifest.published
    releaseZipUri = [string]$manifest.releaseZipUri
    releaseSha256 = if ($manifest.sha256) { [string]$manifest.sha256 } else { $null }
    installedVersion = if ($state) { [string](Get-PropertyValue $state 'version') } else { $null }
    installMode = if ($state) { [string](Get-PropertyValue $state 'installMode') } else { $null }
    statePath = $statePath
    platform = [ordered]@{
        windows = ($env:OS -eq 'Windows_NT')
        x64 = [Environment]::Is64BitOperatingSystem
        supported = $platformSupported
    }
    python = $python
    products = $products
    runningAutodesk = $running
    prerequisiteIssues = @($prerequisiteIssues)
    missingFiles = @($missingFiles)
    changedFiles = @($changedFiles)
    stateError = $stateError
    installLocations = @($manifest.installLocations)
} | ConvertTo-Json -Depth 10
