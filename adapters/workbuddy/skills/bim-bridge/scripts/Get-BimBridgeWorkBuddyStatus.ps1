[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$WorkBuddyVersionOverride
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-RecordedHash($State, [string]$Path) {
    foreach ($file in @($State.files)) {
        if ($file.path -and [IO.Path]::GetFullPath([string]$file.path) -eq $Path) {
            return [string]$file.sha256
        }
    }
    return $null
}

function Find-WorkBuddyVersion {
    if ($WorkBuddyVersionOverride) { return $WorkBuddyVersionOverride }
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^WorkBuddy(?: AI)?' } |
        Select-Object -First 1
    if ($entry) { return [string]$entry.DisplayVersion }
    return $null
}

if (-not $StateRoot) {
    $StateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'BIM Bridge'
}
$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$statePath = Join-Path $StateRoot 'install-state.json'
$workBuddyVersion = Find-WorkBuddyVersion
$state = $null
$stateError = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    catch { $stateError = $_.Exception.Message }
}
if ($state -and $state.schemaVersion -ne 4) { $stateError = 'Unsupported BIM Bridge install-state schema.' }

$missingFiles = New-Object System.Collections.ArrayList
$changedFiles = New-Object System.Collections.ArrayList
$criticalFiles = @()
if ($state -and -not $stateError) {
    foreach ($property in @('launcher', 'python', 'localMcpServer', 'files')) {
        $value = $state.PSObject.Properties[$property]
        if (-not $value -or $null -eq $value.Value -or
            ($property -ne 'files' -and [string]::IsNullOrWhiteSpace([string]$value.Value))) {
            $stateError = "BIM Bridge install state is missing '$property'."
            break
        }
        if ($property -eq 'files') { continue }
        $criticalFiles += [IO.Path]::GetFullPath([string]$value.Value)
    }
}

if (-not $stateError) {
    foreach ($path in $criticalFiles) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$missingFiles.Add($path)
            continue
        }
        $expectedHash = Get-RecordedHash $state $path
        if ([string]::IsNullOrWhiteSpace($expectedHash) -or $expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
            [void]$changedFiles.Add($path)
            continue
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expectedHash.ToUpperInvariant()) {
            [void]$changedFiles.Add($path)
        }
    }
}

$runningAutodesk = @()
foreach ($process in @(Get-Process -Name Revit,acad -ErrorAction SilentlyContinue)) {
    $runningAutodesk += [ordered]@{
        name = $process.ProcessName
        processId = $process.Id
        title = $process.MainWindowTitle
    }
}

$status = 'healthy'
$recommendedAction = 'none'
if (-not $workBuddyVersion) {
    $status = 'workbuddy_not_found'
    $recommendedAction = 'install_workbuddy'
} elseif (-not $state) {
    $status = if ($stateError) { 'needs_repair' } else { 'not_installed' }
    $recommendedAction = if ($stateError) { 'repair_host' } else { 'install_host' }
} elseif ($stateError -or $missingFiles.Count -gt 0 -or $changedFiles.Count -gt 0) {
    $status = 'needs_repair'
    $recommendedAction = 'repair_host'
}

[ordered]@{
    schemaVersion = 1
    adapter = 'workbuddy'
    status = $status
    recommendedAction = $recommendedAction
    workBuddy = [ordered]@{
        installed = [bool]$workBuddyVersion
        version = $workBuddyVersion
        mcpConfiguration = 'manual_ui_required'
    }
    host = [ordered]@{
        statePath = $statePath
        installedVersion = if ($state) { [string]$state.version } else { $null }
        stateSchemaVersion = if ($state) { $state.schemaVersion } else { $null }
        stateError = $stateError
        launcher = if ($state) { [string]$state.launcher } else { $null }
        missingFiles = @($missingFiles)
        changedFiles = @($changedFiles)
    }
    runningAutodesk = $runningAutodesk
} | ConvertTo-Json -Depth 8
