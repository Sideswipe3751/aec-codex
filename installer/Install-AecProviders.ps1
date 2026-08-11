[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall', 'Rollback')]
    [string]$Action = 'Install',
    [string]$SourceRoot,
    [string]$ArtifactsRoot,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $ArtifactsRoot) { $ArtifactsRoot = Join-Path $SourceRoot 'artifacts\providers' }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Copy-Directory([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required provider bundle is missing: $Source"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

function New-SecureToken {
    $bytes = New-Object byte[] 48
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Backup-Target([string]$Path, [string]$BackupRoot, [System.Collections.ArrayList]$Records) {
    if (-not (Test-Path -LiteralPath $Path)) {
        [void]$Records.Add([pscustomobject]@{ Path=$Path; Backup=$null })
        return
    }
    $backup = Join-Path $BackupRoot ([Guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $Path -Destination $backup -Force
    [void]$Records.Add([pscustomobject]@{ Path=$Path; Backup=$backup })
}

function Restore-Targets([System.Collections.ArrayList]$Records) {
    for ($index = $Records.Count - 1; $index -ge 0; $index--) {
        $record = $Records[$index]
        if (Test-Path -LiteralPath $record.Path) {
            Remove-Item -LiteralPath $record.Path -Recurse -Force
        }
        if ($record.Backup -and (Test-Path -LiteralPath $record.Backup)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $record.Path) | Out-Null
            Move-Item -LiteralPath $record.Backup -Destination $record.Path -Force
        }
    }
}

$roaming = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$providerRoot = Join-Path $local 'AEC Codex\providers'
$packageRoot = Join-Path $providerRoot 'packages'
$activeConfig = Join-Path $providerRoot 'active.json'
$previousConfig = Join-Path $providerRoot 'active.previous.json'
$statePath = Join-Path $providerRoot 'install-state.json'
$tokenPath = Join-Path $roaming 'AEC Codex\providers\revit-community.token'
$revitAddinRoot = Join-Path $roaming 'Autodesk\Revit\Addins\2024'
$revitAddinTarget = Join-Path $revitAddinRoot 'AEC Codex Providers'
$revitManifestTarget = Join-Path $revitAddinRoot 'AEC.Codex.Providers.addin'

if ($Action -eq 'Uninstall') {
    if (-not $PSCmdlet.ShouldProcess('AEC Codex structured providers', 'Uninstall')) { return }
    foreach ($target in @($revitAddinTarget, $revitManifestTarget, $providerRoot, $tokenPath)) {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    Write-Host 'AEC Codex structured providers were removed for the current user.'
    return
}

if ($Action -eq 'Rollback') {
    if (-not (Test-Path -LiteralPath $previousConfig)) { throw 'No previous provider configuration is available.' }
    if (-not $PSCmdlet.ShouldProcess('AEC Codex provider configuration', 'Rollback')) { return }
    $current = if (Test-Path -LiteralPath $activeConfig) { Get-Content -LiteralPath $activeConfig -Raw } else { $null }
    $previous = Get-Content -LiteralPath $previousConfig -Raw
    Write-Utf8NoBom $activeConfig $previous
    if ($current) { Write-Utf8NoBom $previousConfig $current }
    Write-Host 'AEC Codex provider configuration was rolled back. Start a new Codex task.'
    return
}

$running = Get-Process -Name Revit,acad -ErrorAction SilentlyContinue
if ($running) { throw 'Close Revit and AutoCAD before installing or repairing structured providers.' }

$lockPath = Join-Path $SourceRoot 'plugins\aec-codex\providers\providers.lock.json'
if (-not (Test-Path -LiteralPath $lockPath)) { throw "Provider lock is missing: $lockPath" }
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$revit = $lock.providers | Where-Object { $_.id -eq 'revit-community' }
$autocad = $lock.providers | Where-Object { $_.id -eq 'autocad-pro' }
if (-not $revit -or -not $autocad) { throw 'Provider lock is incomplete.' }

if (-not $SkipBuild -and -not (Test-Path -LiteralPath (Join-Path $ArtifactsRoot 'build-manifest.json'))) {
    & (Join-Path $SourceRoot 'providers\Build-Providers.ps1') -SourceRoot $SourceRoot -OutputRoot $ArtifactsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Provider bundle build failed.' }
}
if (-not (Test-Path -LiteralPath (Join-Path $ArtifactsRoot 'build-manifest.json'))) {
    throw "Completed provider artifacts are missing: $ArtifactsRoot"
}
$buildManifest = Get-Content -LiteralPath (Join-Path $ArtifactsRoot 'build-manifest.json') -Raw | ConvertFrom-Json
$builtVersions = @{}
foreach ($provider in $buildManifest.providers) { $builtVersions[$provider.id] = $provider.version }
if ($builtVersions['revit-community'] -ne $revit.version -or $builtVersions['autocad-pro'] -ne $autocad.version) {
    throw 'Provider artifact versions do not match providers.lock.json.'
}

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'Python 3.11 or newer is required for the AutoCAD provider.' }
$pythonVersion = & $python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
if ($LASTEXITCODE -ne 0 -or [version]$pythonVersion -lt [version]'3.11') {
    throw "Python 3.11 or newer is required; found $pythonVersion."
}

$revitBundle = Join-Path $ArtifactsRoot ('revit-community\' + $revit.version)
$autocadBundle = Join-Path $ArtifactsRoot ('autocad-pro\' + $autocad.version)
$revitPackage = Join-Path $packageRoot ('revit-community\' + $revit.version)
$autocadPackage = Join-Path $packageRoot ('autocad-pro\' + $autocad.version)
$venvPython = Join-Path $autocadPackage 'venv\Scripts\python.exe'
$autocadCommand = Join-Path $autocadPackage 'venv\Scripts\autocad-mcp.exe'
$nodeCommand = Join-Path $revitPackage 'runtime\node\node.exe'
$revitServer = Join-Path $revitPackage 'server\build\index.js'
$allowedProviderPaths = ((Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Root -Unique) -join ',')

if (-not $PSCmdlet.ShouldProcess('AEC Codex structured providers', $Action)) { return }
$backupRoot = Join-Path $providerRoot ('rollback-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$records = New-Object System.Collections.ArrayList
$oldActiveConfig = if (Test-Path -LiteralPath $activeConfig) { Get-Content -LiteralPath $activeConfig -Raw } else { $null }

try {
    foreach ($target in @($revitPackage, $autocadPackage, $revitAddinTarget, $revitManifestTarget, $activeConfig, $previousConfig, $statePath, $tokenPath)) {
        Backup-Target $target $backupRoot $records
    }

    Copy-Directory $revitBundle $revitPackage
    Copy-Directory $autocadBundle $autocadPackage

    & $python -m venv (Join-Path $autocadPackage 'venv')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the AutoCAD provider Python environment.' }
    $providerWheel = Get-ChildItem -LiteralPath $autocadPackage -Filter 'autocad_mcp_pro-*.whl' -File | Select-Object -First 1
    if (-not $providerWheel) { throw 'AutoCAD provider wheel is missing from the bundle.' }
    & $venvPython -m pip install --disable-pip-version-check --no-input ($providerWheel.FullName + '[com]')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to install the AutoCAD provider and COM dependencies.' }
    if (-not (Test-Path -LiteralPath $autocadCommand)) { throw 'AutoCAD provider command was not installed.' }
    if (-not (Test-Path -LiteralPath $nodeCommand) -or -not (Test-Path -LiteralPath $revitServer)) {
        throw 'Revit provider runtime is incomplete.'
    }

    Copy-Directory (Join-Path $revitPackage 'addin\revit_mcp_plugin') $revitAddinTarget
    New-Item -ItemType Directory -Force -Path $revitAddinRoot | Out-Null
    $manifest = Get-Content -LiteralPath (Join-Path $revitPackage 'addin\mcp-servers-for-revit.addin') -Raw
    $assemblyPath = Join-Path $revitAddinTarget 'RevitMCPPlugin.dll'
    $manifest = $manifest -replace '<Assembly>.*?</Assembly>', ('<Assembly>' + [Security.SecurityElement]::Escape($assemblyPath) + '</Assembly>')
    Write-Utf8NoBom $revitManifestTarget $manifest

    $token = New-SecureToken
    Write-Utf8NoBom $tokenPath $token
    if ($oldActiveConfig) { Write-Utf8NoBom $previousConfig $oldActiveConfig }

    $config = [ordered]@{
        schemaVersion = 1
        activatedAtUtc = [DateTime]::UtcNow.ToString('o')
        providers = @(
            [ordered]@{
                id='revit-community'; application='revit'; displayName='mcp-servers-for-revit'; version=$revit.version; enabled=$true
                source=$revit.repository; command=$nodeCommand; args=@($revitServer); cwd=(Split-Path -Parent $revitServer)
                startupTimeoutSeconds=30; env=[ordered]@{ AEC_CODEX_PROVIDER_TOKEN=$token }
            },
            [ordered]@{
                id='autocad-pro'; application='autocad'; displayName='U-C4N AutoCAD MCP'; version=$autocad.version; enabled=$true
                source=$autocad.repository; command=$autocadCommand; args=@(); cwd=$autocadPackage
                startupTimeoutSeconds=60; env=[ordered]@{
                    AUTOCAD_MCP_BACKEND='com'; TOOL_PROFILE='lean'; ALLOWED_PATHS=$allowedProviderPaths
                    ALLOW_REMOTE_HTTP='false'; DANGEROUS_COMMANDS_ENABLED='false'
                }
            }
        )
    }
    Write-Utf8NoBom $activeConfig ($config | ConvertTo-Json -Depth 10)
    Write-Utf8NoBom $statePath (([ordered]@{
        installedAtUtc=[DateTime]::UtcNow.ToString('o'); lockSchemaVersion=$lock.schemaVersion
        revitProvider=$revit.version; autocadProvider=$autocad.version; activeConfig=$activeConfig
        revitAddin=$revitManifestTarget
    }) | ConvertTo-Json -Depth 5)

    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'AEC Codex structured providers were installed. Restart Revit and start a new Codex task.'
} catch {
    Restore-Targets $records
    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    throw "Structured provider installation failed and was rolled back: $($_.Exception.Message)"
}
