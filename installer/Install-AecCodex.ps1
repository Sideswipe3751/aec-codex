[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Install',
    [ValidateSet('HostOnly', 'Development')]
    [string]$InstallMode = 'Development',
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

function New-FileRecord([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Installed file is missing before state commit: $Path"
    }
    [ordered]@{
        path = $Path
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
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
$hostRoot = Join-Path $stateRoot 'host'
$maintenanceRoot = Join-Path $stateRoot 'maintenance'
$baseTargets = @($revitDllTarget, $revitManifestTarget, $cadBundleTarget, $hostRoot, $maintenanceRoot, $statePath)
$targets = if ($InstallMode -eq 'Development') { @($baseTargets) + @($pluginTarget) } else { @($baseTargets) }

if ($Action -eq 'Uninstall') {
    if (-not $PSCmdlet.ShouldProcess("AEC Codex current-user $InstallMode installation", 'Uninstall')) { return }
    if (-not $SkipProviders) {
        & (Join-Path $SourceRoot 'installer\Install-AecProviders.ps1') -Action Uninstall -SourceRoot $SourceRoot -Confirm:$false
    }
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    if ($InstallMode -eq 'Development') {
        if (Test-Path -LiteralPath $marketplaceTarget) {
            $marketplace = Get-Content -LiteralPath $marketplaceTarget -Raw | ConvertFrom-Json
            $marketplace.plugins = @($marketplace.plugins | Where-Object { $_.name -ne 'aec-codex' })
            Write-Utf8NoBom $marketplaceTarget ($marketplace | ConvertTo-Json -Depth 10)
        }
        $cli = Find-CodexCli
        if ($cli) { try { & $cli plugin remove 'aec-codex@personal' *> $null } catch { } }
    }
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
    if ($InstallMode -eq 'HostOnly') {
        Write-Host 'AEC Codex host components were removed. The marketplace plugin was preserved.'
    } else {
        Write-Host 'AEC Codex development installation was removed from the current user.'
    }
    return
}

$running = Get-Process -Name Revit,acad -ErrorAction SilentlyContinue
if ($running) { throw 'Close Revit and AutoCAD before installing or repairing AEC Codex.' }
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw 'Python 3.11 or newer is required by the local MCP host.' }
$pythonVersion = & $python.Source -c 'import sys;print(sys.version_info.major,sys.version_info.minor,sep=chr(46))'
if ($LASTEXITCODE -ne 0 -or [version]$pythonVersion -lt [version]'3.11') {
    throw "Python 3.11 or newer is required; found $pythonVersion."
}
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'plugins\aec-codex\.codex-plugin\plugin.json'))) {
    throw "AEC Codex source/release root is invalid: $SourceRoot"
}
$sourcePluginManifest = Join-Path $SourceRoot 'plugins\aec-codex\.codex-plugin\plugin.json'
$sourcePluginJson = Get-Content -LiteralPath $sourcePluginManifest -Raw | ConvertFrom-Json
$releaseVersion = ([string]$sourcePluginJson.version) -replace '\+.*$',''
if ($releaseVersion -ne '1.1.0-rc.2') { throw "This installer requires AEC Codex 1.1.0-rc.2; found $releaseVersion." }
if ($InstallMode -eq 'Development' -and -not (Test-Path -LiteralPath (Join-Path $SourceRoot 'plugins\aec-codex\skills\aec-codex\SKILL.md'))) {
    throw 'Development mode requires a full source checkout. The release host payload supports HostOnly mode.'
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

if (-not $PSCmdlet.ShouldProcess("AEC Codex current-user $InstallMode installation", $Action)) { return }
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$backupRoot = Join-Path $stateRoot ('rollback-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$records = New-Object System.Collections.ArrayList

try {
    foreach ($target in $targets) { Backup-Path $target $backupRoot $records }
    if ($InstallMode -eq 'Development') {
        Backup-Path $marketplaceTarget $backupRoot $records
        $marketplaceRecord = $records[$records.Count - 1]
        if ($marketplaceRecord.Backup) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marketplaceTarget) | Out-Null
            Copy-Item -LiteralPath $marketplaceRecord.Backup -Destination $marketplaceTarget -Force
        }
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

    $codexRegistered = $false
    if ($InstallMode -eq 'Development') {
        Copy-Directory (Join-Path $SourceRoot 'plugins\aec-codex') $pluginTarget
        $pluginManifest = Join-Path $pluginTarget '.codex-plugin\plugin.json'
        $pluginJson = Get-Content -LiteralPath $pluginManifest -Raw | ConvertFrom-Json
        $basePluginVersion = $pluginJson.version -replace '\+.*$',''
        $pluginJson.version = $basePluginVersion + '+codex.local-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        Write-Utf8NoBom $pluginManifest ($pluginJson | ConvertTo-Json -Depth 10)
        Update-PersonalMarketplace $marketplaceTarget

        $cli = Find-CodexCli
        if ($cli) {
            & $cli plugin add 'aec-codex@personal'
            $codexRegistered = ($LASTEXITCODE -eq 0)
        }
        if (-not $codexRegistered) {
            throw 'Autodesk connectors were staged, but Codex development plugin registration failed.'
        }
    }

    $versionedHostRoot = Join-Path $hostRoot $releaseVersion
    Copy-Directory (Join-Path $SourceRoot 'plugins\aec-codex\mcp-server') (Join-Path $versionedHostRoot 'mcp-server')
    Copy-Directory (Join-Path $SourceRoot 'installer') (Join-Path $maintenanceRoot 'installer')
    $localMcpServer = Join-Path $versionedHostRoot 'mcp-server\aec_mcp_server.py'
    $uninstaller = Join-Path $maintenanceRoot 'installer\Install-AecCodex.ps1'
    $stateFiles = @(
        (New-FileRecord (Join-Path $revitDllTarget 'Aec.Codex.Revit2024.dll')),
        (New-FileRecord $revitManifestTarget),
        (New-FileRecord (Join-Path $cadBundleTarget 'Contents\Windows\Aec.Codex.AutoCAD2024.dll')),
        (New-FileRecord (Join-Path $cadBundleTarget 'PackageContents.xml')),
        (New-FileRecord $localMcpServer),
        (New-FileRecord $uninstaller)
    )
    if (-not $SkipProviders) {
        $stateFiles += @(
            [ordered]@{ path=(Join-Path $stateRoot 'providers\active.json'); sha256=$null },
            [ordered]@{ path=(Join-Path $roaming 'Autodesk\Revit\Addins\2024\AEC.Codex.Providers.addin'); sha256=$null }
        )
    }
    [ordered]@{
        schemaVersion = 2
        version = $releaseVersion
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        installMode = $InstallMode
        restartRequired = $true
        revit2024 = $revitDllTarget
        autocad2024 = $cadBundleTarget
        localMcpServer = $localMcpServer
        uninstaller = $uninstaller
        codexPlugin = if ($InstallMode -eq 'Development') { $pluginTarget } else { $null }
        providersInstalled = (-not $SkipProviders)
        files = $stateFiles
    } | ConvertTo-Json -Depth 8 | ForEach-Object { Write-Utf8NoBom $statePath $_ }

    if (-not $SkipProviders) {
        & (Join-Path $SourceRoot 'installer\Install-AecProviders.ps1') -Action $Action -SourceRoot $SourceRoot -SkipBuild:$SkipBuild -Confirm:$false
    }

    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "AEC Codex $releaseVersion $InstallMode installation succeeded. Restart Codex, Revit, and AutoCAD before testing."
} catch {
    $failure = $_.Exception.Message
    Restore-Backups $records
    $rollbackCli = if ($InstallMode -eq 'Development') { Find-CodexCli } else { $null }
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
