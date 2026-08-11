[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$SourceRoot,
    [switch]$SkipBuild,
    [switch]$SkipProviders
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}

function Get-UserPath([Environment+SpecialFolder]$Folder) {
    [Environment]::GetFolderPath($Folder)
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Copy-Directory([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required source directory is missing: $Source"
    }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

function Backup-Path([string]$Path, [string]$BackupRoot, [System.Collections.ArrayList]$Records) {
    if (-not (Test-Path -LiteralPath $Path)) {
        [void]$Records.Add([pscustomobject]@{ Path = $Path; Backup = $null })
        return
    }
    $backup = Join-Path $BackupRoot ([Guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $Path -Destination $backup -Force
    [void]$Records.Add([pscustomobject]@{ Path = $Path; Backup = $backup })
}

function Restore-Backups([System.Collections.ArrayList]$Records) {
    for ($index = $Records.Count - 1; $index -ge 0; $index--) {
        $record = $Records[$index]
        if (Test-Path -LiteralPath $record.Path) { Remove-Item -LiteralPath $record.Path -Recurse -Force }
        if ($record.Backup -and (Test-Path -LiteralPath $record.Backup)) {
            Move-Item -LiteralPath $record.Backup -Destination $record.Path -Force
        }
    }
}

function Find-CodexCli {
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) {
        try { & $command.Source --version *> $null; if ($LASTEXITCODE -eq 0) { return $command.Source } } catch { }
    }
    $localAppData = Get-UserPath LocalApplicationData
    $candidateRoot = Join-Path $localAppData 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $candidateRoot) {
        $candidate = Get-ChildItem -LiteralPath $candidateRoot -Filter codex.exe -File -Recurse |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}

function Update-PersonalMarketplace([string]$MarketplacePath) {
    $entry = [ordered]@{
        name = 'aec-codex'
        source = [ordered]@{ source = 'local'; path = './plugins/aec-codex' }
        policy = [ordered]@{ installation = 'AVAILABLE'; authentication = 'ON_INSTALL' }
        category = 'Productivity'
    }
    if (Test-Path -LiteralPath $MarketplacePath) {
        $marketplace = Get-Content -LiteralPath $MarketplacePath -Raw | ConvertFrom-Json
        if (-not $marketplace.plugins) { $marketplace | Add-Member -NotePropertyName plugins -NotePropertyValue @() -Force }
        $remaining = @($marketplace.plugins | Where-Object { $_.name -ne 'aec-codex' })
        $marketplace.plugins = @($remaining) + @($entry)
    } else {
        $marketplace = [ordered]@{
            name = 'personal'
            interface = [ordered]@{ displayName = 'Personal' }
            plugins = @($entry)
        }
    }
    $directory = Split-Path -Parent $MarketplacePath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = "$MarketplacePath.tmp"
    Write-Utf8NoBom $temporary ($marketplace | ConvertTo-Json -Depth 10)
    Move-Item -LiteralPath $temporary -Destination $MarketplacePath -Force
}

$roaming = Get-UserPath ApplicationData
$local = Get-UserPath LocalApplicationData
$profile = Get-UserPath UserProfile
$revitAddinRoot = Join-Path $roaming 'Autodesk\Revit\Addins\2024'
$revitDllTarget = Join-Path $revitAddinRoot 'AEC Codex'
$revitManifestTarget = Join-Path $revitAddinRoot 'AEC.Codex.addin'
$cadBundleTarget = Join-Path $roaming 'Autodesk\ApplicationPlugins\AEC Codex.bundle'
$pluginTarget = Join-Path $profile 'plugins\aec-codex'
$marketplaceTarget = Join-Path $profile '.agents\plugins\marketplace.json'
$stateRoot = Join-Path $local 'AEC Codex'
$statePath = Join-Path $stateRoot 'install-state.json'
$targets = @($revitDllTarget, $revitManifestTarget, $cadBundleTarget, $pluginTarget, $statePath)

if ($Action -eq 'Uninstall') {
    if (-not $PSCmdlet.ShouldProcess('AEC Codex current-user installation', 'Uninstall')) { return }
    if (-not $SkipProviders) {
        & (Join-Path $SourceRoot 'installer\Install-AecProviders.ps1') -Action Uninstall -SourceRoot $SourceRoot -Confirm:$false
    }
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    if (Test-Path -LiteralPath $marketplaceTarget) {
        $marketplace = Get-Content -LiteralPath $marketplaceTarget -Raw | ConvertFrom-Json
        $marketplace.plugins = @($marketplace.plugins | Where-Object { $_.name -ne 'aec-codex' })
        Write-Utf8NoBom $marketplaceTarget ($marketplace | ConvertTo-Json -Depth 10)
    }
    $cli = Find-CodexCli
    if ($cli) { try { & $cli plugin remove 'aec-codex@personal' *> $null } catch { } }
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
    Write-Host 'AEC Codex was removed from the current user.'
    return
}

$running = Get-Process -Name Revit,acad -ErrorAction SilentlyContinue
if ($running) { throw 'Close Revit and AutoCAD before installing or repairing AEC Codex.' }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw 'Python 3 is required by the local MCP host.' }
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'plugins\aec-codex\.codex-plugin\plugin.json'))) {
    throw "AEC Codex source/release root is invalid: $SourceRoot"
}

if (-not $SkipBuild) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET SDK is required to build this source checkout.' }
    & dotnet build (Join-Path $SourceRoot 'AEC.Codex.slnx') -c Release
    if ($LASTEXITCODE -ne 0) { throw 'AEC Codex build failed.' }
}

$revitSource = Join-Path $SourceRoot 'src\Aec.Codex.Revit2024\bin\Release\net48'
$cadSource = Join-Path $SourceRoot 'src\Aec.Codex.AutoCAD2024\bin\Release\net48'
if (-not (Test-Path -LiteralPath (Join-Path $revitSource 'Aec.Codex.Revit2024.dll'))) { throw 'Revit 2024 release binaries are missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $cadSource 'Aec.Codex.AutoCAD2024.dll'))) { throw 'AutoCAD 2024 release binaries are missing.' }

if (-not $PSCmdlet.ShouldProcess('AEC Codex current-user installation', $Action)) { return }
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$backupRoot = Join-Path $stateRoot ('rollback-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$records = New-Object System.Collections.ArrayList

try {
    foreach ($target in $targets) { Backup-Path $target $backupRoot $records }
    Backup-Path $marketplaceTarget $backupRoot $records
    $marketplaceRecord = $records[$records.Count - 1]
    if ($marketplaceRecord.Backup) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marketplaceTarget) | Out-Null
        Copy-Item -LiteralPath $marketplaceRecord.Backup -Destination $marketplaceTarget -Force
    }

    Copy-Directory $revitSource $revitDllTarget
    New-Item -ItemType Directory -Force -Path $revitAddinRoot | Out-Null
    $assemblyPath = Join-Path $revitDllTarget 'Aec.Codex.Revit2024.dll'
    $manifest = Get-Content -LiteralPath (Join-Path $SourceRoot 'src\Aec.Codex.Revit2024\Aec.Codex.Revit2024.addin') -Raw
    $manifest = $manifest -replace '<Assembly>.*?</Assembly>', ('<Assembly>' + [Security.SecurityElement]::Escape($assemblyPath) + '</Assembly>')
    Set-Content -LiteralPath $revitManifestTarget -Value $manifest -Encoding UTF8

    New-Item -ItemType Directory -Force -Path (Join-Path $cadBundleTarget 'Contents') | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'src\Aec.Codex.AutoCAD2024\PackageContents.xml') -Destination $cadBundleTarget -Force
    Copy-Directory $cadSource (Join-Path $cadBundleTarget 'Contents\Windows')

    Copy-Directory (Join-Path $SourceRoot 'plugins\aec-codex') $pluginTarget
    $pluginManifest = Join-Path $pluginTarget '.codex-plugin\plugin.json'
    $pluginJson = Get-Content -LiteralPath $pluginManifest -Raw | ConvertFrom-Json
    $basePluginVersion = $pluginJson.version -replace '\+.*$',''
    $pluginJson.version = $basePluginVersion + '+codex.local-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    Write-Utf8NoBom $pluginManifest ($pluginJson | ConvertTo-Json -Depth 10)
    Update-PersonalMarketplace $marketplaceTarget

    $cli = Find-CodexCli
    $codexRegistered = $false
    if ($cli) {
        & $cli plugin add 'aec-codex@personal'
        $codexRegistered = ($LASTEXITCODE -eq 0)
    }
    if (-not $codexRegistered) {
        throw 'Autodesk connectors were staged, but Codex plugin registration failed.'
    }

    [ordered]@{
        version = '1.1.0'
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        sourceRoot = $SourceRoot
        revit2024 = $revitDllTarget
        autocad2024 = $cadBundleTarget
        codexPlugin = $pluginTarget
    } | ConvertTo-Json -Depth 5 | ForEach-Object { Write-Utf8NoBom $statePath $_ }

    if (-not $SkipProviders) {
        & (Join-Path $SourceRoot 'installer\Install-AecProviders.ps1') -Action $Action -SourceRoot $SourceRoot -SkipBuild:$SkipBuild -Confirm:$false
    }

    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'AEC Codex 1.1 was installed successfully. Restart Codex, Revit, and AutoCAD before testing.'
} catch {
    $failure = $_.Exception.Message
    Restore-Backups $records
    $rollbackCli = Find-CodexCli
    if ($rollbackCli) {
        try {
            if (Test-Path -LiteralPath $pluginTarget) {
                & $rollbackCli plugin add 'aec-codex@personal' *> $null
            } else {
                & $rollbackCli plugin remove 'aec-codex@personal' *> $null
            }
        } catch { }
    }
    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
    throw "AEC Codex installation failed and was rolled back: $failure"
}
