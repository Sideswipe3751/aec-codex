[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$StateRoot,
    [string]$RoamingRoot,
    [string]$LocalRoot,
    [string]$ProgramFilesRoot,
    [string]$ProgramFilesX86Root,
    [hashtable]$ProductInstallPathOverrides,
    [object[]]$RegistryInstallRecords,
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

function Get-DescriptorDirectoryEvidence([string]$Directory) {
    $files = @()
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{
                name = $_.Name
                length = [long]$_.Length
                lastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
            }
        })
    }
    [ordered]@{ directory=$Directory; exists=(Test-Path -LiteralPath $Directory -PathType Container); files=$files }
}

function Get-FileEvidence([string]$Path) {
    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    [ordered]@{
        path=$Path
        exists=[bool]$file
        length=if ($file) { [long]$file.Length } else { $null }
        lastWriteTimeUtc=if ($file) { $file.LastWriteTimeUtc.ToString('o') } else { $null }
    }
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

function Convert-AutodeskRuntimeTfm([string]$RuntimeTfm, [string]$RuntimeConfigPath) {
    switch -Regex ($RuntimeTfm) {
        '^net8(\.0)?$' { return 'net8.0-windows' }
        '^net10(\.0)?$' { return 'net10.0-windows' }
        default { throw "Unsupported Autodesk runtime '$RuntimeTfm' at $RuntimeConfigPath" }
    }
}

function Get-CertifiedTargets($Manifest, [string]$Product, [string]$Version) {
    $variantRoot = Get-PropertyValue $Manifest 'certifiedVariants'
    $variants = Get-PropertyValue $variantRoot $Product
    @($variants | Where-Object { [string]$_.version -eq $Version } | ForEach-Object { [string]$_.targetFramework })
}

function Get-ProductStatus(
    $Manifest,
    [string]$Product,
    [string]$Version,
    $Installation,
    [string]$RuntimeConfigName
) {
    $installPath = if ($Installation) { [string]$Installation.InstallDirectory } else { $null }
    $certifiedTargets = @(Get-CertifiedTargets $Manifest $Product $Version)
    $targetFramework = $null
    $detectedRuntime = $null
    $issue = $null
    if ($installPath) {
        if ($certifiedTargets.Count -eq 1 -and $certifiedTargets[0] -eq 'net48') {
            $targetFramework = 'net48'
        } else {
            $runtimeConfigPath = Join-Path $installPath $RuntimeConfigName
            try {
                if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
                    throw "runtime metadata is missing: $runtimeConfigPath"
                }
                $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw | ConvertFrom-Json
                $detectedRuntime = [string]$runtimeConfig.runtimeOptions.tfm
                $targetFramework = Convert-AutodeskRuntimeTfm $detectedRuntime $runtimeConfigPath
            } catch {
                $issue = "$Product $Version runtime could not be resolved: $($_.Exception.Message)"
            }
        }
        if (-not $issue -and $certifiedTargets -notcontains $targetFramework) {
            $available = if ($certifiedTargets.Count -gt 0) { $certifiedTargets -join ', ' } else { 'none' }
            $issue = "$Product $Version target framework $targetFramework is not certified for BIM Bridge $([string]$Manifest.version). Certified target frameworks: $available."
        }
    }
    [pscustomobject]@{
        Product = $Product
        Version = $Version
        Status = [ordered]@{
            version=$Version
            installed=[bool]$installPath
            targetFramework=$targetFramework
            detectedRuntime=$detectedRuntime
            certified=([bool]$installPath -and -not $issue)
            certifiedTargetFrameworks=$certifiedTargets
            installPath=$installPath
            detectionSource=if ($Installation) { [string]$Installation.Source } else { $null }
        }
        Issue = $issue
    }
}

if (-not $ManifestPath) { $ManifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'release-manifest.json' }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Release manifest is missing: $ManifestPath" }
. (Join-Path $PSScriptRoot 'Test-BimBridgeReleaseManifest.ps1')
. (Join-Path $PSScriptRoot 'AutodeskProductDiscovery.ps1')
$manifest = Read-VerifiedBimBridgeReleaseManifest $ManifestPath
if ($manifest.schemaVersion -ne 2) { throw "Unsupported BIM Bridge release manifest schema: $($manifest.schemaVersion)" }

if (-not $RoamingRoot) { $RoamingRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData) }
if (-not $LocalRoot) { $LocalRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) }
if (-not $StateRoot) { $StateRoot = Join-Path $LocalRoot 'BIM Bridge' }
if (-not $ProgramFilesRoot) { $ProgramFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles) }
if (-not $ProgramFilesX86Root) { $ProgramFilesX86Root = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86) }

$platformSupported = ($env:OS -eq 'Windows_NT' -and [Environment]::Is64BitOperatingSystem)
$prerequisiteIssues = New-Object System.Collections.ArrayList
$compatibilityIssues = New-Object System.Collections.ArrayList
if (-not $platformSupported) { [void]$prerequisiteIssues.Add('BIM Bridge requires 64-bit Windows.') }

$programRoots = @($ProgramFilesRoot, $ProgramFilesX86Root)
$registryRecords = if ($PSBoundParameters.ContainsKey('RegistryInstallRecords')) { @($RegistryInstallRecords) } else { @(Get-AutodeskRegistryInstallRecords) }
$revitResults = @($manifest.supportedProducts.revit | ForEach-Object {
    $installation = Resolve-AutodeskProductInstallation -Product revit -Version ([string]$_) `
        -InstallSubdirectory ('Autodesk\Revit ' + [string]$_) -ProgramFilesRoots $programRoots `
        -ProductInstallPathOverrides $ProductInstallPathOverrides -RegistryInstallRecords $registryRecords
    Get-ProductStatus $manifest 'revit' ([string]$_) $installation 'RevitAPI.runtimeconfig.json'
})
$autocadResults = @($manifest.supportedProducts.autocad | ForEach-Object {
    $installation = Resolve-AutodeskProductInstallation -Product autocad -Version ([string]$_) `
        -InstallSubdirectory ('Autodesk\AutoCAD ' + [string]$_) -ProgramFilesRoots $programRoots `
        -ProductInstallPathOverrides $ProductInstallPathOverrides -RegistryInstallRecords $registryRecords
    Get-ProductStatus $manifest 'autocad' ([string]$_) $installation 'acdbmgd.runtimeconfig.json'
})
$revitProducts = @($revitResults | ForEach-Object { $_.Status })
$autocadProducts = @($autocadResults | ForEach-Object { $_.Status })
foreach ($issue in @($revitResults + $autocadResults | ForEach-Object { $_.Issue } | Where-Object { $_ })) {
    [void]$compatibilityIssues.Add([string]$issue)
}
$skippedProducts = @($revitResults + $autocadResults | Where-Object { $_.Issue } | ForEach-Object {
    [ordered]@{ product=$_.Product; version=$_.Version; reason=$_.Issue }
})

$running = @()
foreach ($process in @(Get-Process -Name Revit,acad -ErrorAction SilentlyContinue)) {
    $running += [ordered]@{ name=$process.ProcessName; processId=$process.Id; title=$process.MainWindowTitle }
}

$connectorDiscovery = [ordered]@{
    current = Get-DescriptorDirectoryEvidence (Join-Path $RoamingRoot 'BIM Bridge\instances')
    legacy = Get-DescriptorDirectoryEvidence (Join-Path $RoamingRoot 'AEC Codex\instances')
    startupErrors = Get-FileEvidence (Join-Path $RoamingRoot 'BIM Bridge\connector-errors.log')
    note = 'BIM Bridge 2.x writes descriptors to the current directory. The legacy directory is read only as a compatibility fallback.'
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
    connectorDiscovery = $connectorDiscovery
    prerequisiteIssues = @($prerequisiteIssues)
    compatibilityIssues = @($compatibilityIssues)
    skippedProducts = @($skippedProducts)
    missingFiles = @($missingFiles)
    changedFiles = @($changedFiles)
    stateError = $stateError
    installLocations = @($manifest.installLocations)
    legacy = [ordered]@{ detected=$legacyDetected; statePath=$legacyStatePath; pluginRoot=$legacyPluginRoot }
} | ConvertTo-Json -Depth 10
