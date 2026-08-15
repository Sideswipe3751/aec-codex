[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$StateRoot,
    [string]$RoamingRoot,
    [string]$LocalRoot,
    [string]$ProgramFilesRoot,
    [string]$ProgramFilesX86Root,
    [string]$CodexStartedAtUtc,
    [Nullable[bool]]$CodexMcpRegisteredOverride
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

function ConvertTo-UtcDateTime($Value) {
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
    return [datetime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}

function Find-CodexCli {
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) {
        try { & $command.Source --version *> $null; if ($LASTEXITCODE -eq 0) { return $command.Source } } catch { }
    }
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $candidate = Join-Path $profile '.codex\plugins\.plugin-appserver\codex.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        try { & $candidate --version *> $null; if ($LASTEXITCODE -eq 0) { return $candidate } } catch { }
    }
    return $null
}

function Test-ProductPath([string[]]$Roots, [string]$RelativePath) {
    foreach ($root in $Roots) {
        if ($root -and (Test-Path -LiteralPath (Join-Path $root $RelativePath))) { return $true }
    }
    return $false
}

if (-not $ManifestPath) { $ManifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'release-manifest.json' }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Release manifest is missing: $ManifestPath" }
. (Join-Path $PSScriptRoot 'Test-BimBridgeReleaseManifest.ps1')
$manifest = Read-VerifiedBimBridgeReleaseManifest $ManifestPath
if ($manifest.schemaVersion -ne 2) { throw "Unsupported BIM Bridge release manifest schema: $($manifest.schemaVersion)" }

if (-not $RoamingRoot) { $RoamingRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData) }
if (-not $LocalRoot) { $LocalRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) }
if (-not $StateRoot) { $StateRoot = Join-Path $LocalRoot 'BIM Bridge' }
if (-not $ProgramFilesRoot) { $ProgramFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles) }
if (-not $ProgramFilesX86Root) { $ProgramFilesX86Root = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86) }

$platformSupported = ($env:OS -eq 'Windows_NT' -and [Environment]::Is64BitOperatingSystem)
$prerequisiteIssues = New-Object System.Collections.ArrayList
if (-not $platformSupported) { [void]$prerequisiteIssues.Add('BIM Bridge requires 64-bit Windows.') }

$programRoots = @($ProgramFilesRoot, $ProgramFilesX86Root)
$revitProducts = @($manifest.supportedProducts.revit | ForEach-Object {
    [ordered]@{ version=[string]$_; installed=(Test-ProductPath $programRoots ('Autodesk\Revit ' + [string]$_)) }
})
$autocadProducts = @($manifest.supportedProducts.autocad | ForEach-Object {
    [ordered]@{ version=[string]$_; installed=(Test-ProductPath $programRoots ('Autodesk\AutoCAD ' + [string]$_)) }
})

$running = @()
foreach ($process in @(Get-Process -Name Revit,acad -ErrorAction SilentlyContinue)) {
    $running += [ordered]@{ name=$process.ProcessName; processId=$process.Id; title=$process.MainWindowTitle }
}

$statePath = Join-Path $StateRoot 'install-state.json'
$state = $null
$stateError = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    catch { $stateError = $_.Exception.Message }
}
if ($state -and (Get-PropertyValue $state 'schemaVersion') -ne 4) {
    $stateError = 'Unsupported or missing BIM Bridge install-state schema.'
}
if ($state -and -not $stateError) {
    foreach ($requiredProperty in @('version','localMcpServer','python','launcher','ownedPaths','files')) {
        if (-not (Get-PropertyValue $state $requiredProperty)) {
            $stateError = "BIM Bridge install state is missing '$requiredProperty'."
            break
        }
    }
}

$codexCli = Find-CodexCli
$mcpName = [string]$manifest.mcpRegistration
$mcpRegistered = $false
if ($PSBoundParameters.ContainsKey('CodexMcpRegisteredOverride')) {
    $mcpRegistered = [bool]$CodexMcpRegisteredOverride
} elseif ($codexCli) {
    try {
        & $codexCli mcp get $mcpName --json *> $null
        $mcpRegistered = ($LASTEXITCODE -eq 0)
    } catch { $mcpRegistered = $false }
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

$legacyStateRoot = Join-Path $LocalRoot 'AEC Codex'
$legacyStatePath = Join-Path $legacyStateRoot 'install-state.json'
$legacyPluginRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) 'plugins\aec-codex'
$legacyDetected = (Test-Path -LiteralPath $legacyStatePath -PathType Leaf) -or (Test-Path -LiteralPath $legacyPluginRoot -PathType Container)
$knownInstallArtifacts = @(
    (Join-Path $StateRoot 'host'),
    (Join-Path $StateRoot 'connectors'),
    (Join-Path $RoamingRoot 'Autodesk\ApplicationPlugins\BIM Bridge.bundle')
) + @($manifest.supportedProducts.revit | ForEach-Object {
    Join-Path $RoamingRoot ("Autodesk\Revit\Addins\$($_)\BIM.Bridge.addin")
})
$partialInstallDetected = @($knownInstallArtifacts | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0

$restartRequired = $false
$stateInstalledAtUtc = Get-PropertyValue $state 'installedAtUtc'
if ($state -and $stateInstalledAtUtc) {
    $installedAt = ConvertTo-UtcDateTime $stateInstalledAtUtc
    $codexStart = $null
    if ($CodexStartedAtUtc) {
        $codexStart = ConvertTo-UtcDateTime $CodexStartedAtUtc
    } else {
        foreach ($process in @(Get-Process -Name Codex,ChatGPT -ErrorAction SilentlyContinue)) {
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
    if ($stateError -or $partialInstallDetected -or $mcpRegistered) { $status = 'needs_repair'; $recommendedAction = 'repair' }
    elseif ($prerequisiteIssues.Count -gt 0) { $status = 'needs_prerequisite'; $recommendedAction = 'install_prerequisite' }
    else { $status = 'not_installed'; $recommendedAction = 'install' }
} elseif ($stateError -or $missingFiles.Count -gt 0 -or $changedFiles.Count -gt 0 -or -not $mcpRegistered) {
    $status = 'needs_repair'; $recommendedAction = 'repair'
} elseif ([string](Get-PropertyValue $state 'version') -ne [string]$manifest.version) {
    $status = 'needs_upgrade'; $recommendedAction = 'upgrade'
} elseif ($prerequisiteIssues.Count -gt 0) {
    $status = 'needs_prerequisite'; $recommendedAction = 'install_prerequisite'
} elseif ($restartRequired) {
    $status = 'restart_required'; $recommendedAction = 'restart'
}

[ordered]@{
    schemaVersion = 2
    status = $status
    recommendedAction = $recommendedAction
    targetVersion = [string]$manifest.version
    releasePublished = [bool]$manifest.published
    releaseZipUri = if ($manifest.releaseZipUri) { [string]$manifest.releaseZipUri } else { $null }
    releaseSha256 = if ($manifest.sha256) { [string]$manifest.sha256 } else { $null }
    installedVersion = if ($state) { [string](Get-PropertyValue $state 'version') } else { $null }
    statePath = $statePath
    platform = [ordered]@{ windows=($env:OS -eq 'Windows_NT'); x64=[Environment]::Is64BitOperatingSystem; supported=$platformSupported }
    codexMcp = [ordered]@{ name=$mcpName; required=$true; cliFound=[bool]$codexCli; registered=[bool]$mcpRegistered }
    products = [ordered]@{ autocad=$autocadProducts; revit=$revitProducts }
    runningAutodesk = $running
    prerequisiteIssues = @($prerequisiteIssues)
    missingFiles = @($missingFiles)
    changedFiles = @($changedFiles)
    stateError = $stateError
    installLocations = @($manifest.installLocations)
    legacy = [ordered]@{ detected=$legacyDetected; statePath=$legacyStatePath; pluginRoot=$legacyPluginRoot }
} | ConvertTo-Json -Depth 10
