[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Check', 'StageLocked', 'Activate', 'Rollback', 'Snapshot')]
    [string]$Action = 'Check',
    [string]$SourceRoot,
    [string]$ArtifactsRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $ArtifactsRoot) { $ArtifactsRoot = Join-Path $SourceRoot 'artifacts\providers' }

$lockPath = Join-Path $SourceRoot 'plugins\aec-codex\providers\providers.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$revit = $lock.providers | Where-Object { $_.id -eq 'revit-community' }
$autocad = $lock.providers | Where-Object { $_.id -eq 'autocad-pro' }

if ($Action -eq 'Check') {
    $headers = @{ 'User-Agent'='AEC-Codex-Updater'; 'Accept'='application/vnd.github+json' }
    $revitLatest = Invoke-RestMethod -Uri 'https://api.github.com/repos/mcp-servers-for-revit/mcp-servers-for-revit/releases/latest' -Headers $headers
    $autocadLatest = Invoke-RestMethod -Uri 'https://api.github.com/repos/U-C4N/Autocad-MCP/releases/latest' -Headers $headers
    [ordered]@{
        checkedAtUtc=[DateTime]::UtcNow.ToString('o')
        providers=@(
            [ordered]@{ id='revit-community'; installed=$revit.version; latest=($revitLatest.tag_name -replace '^v',''); updateAvailable=(('v' + $revit.version) -ne $revitLatest.tag_name); url=$revitLatest.html_url },
            [ordered]@{ id='autocad-pro'; installed=$autocad.version; latest=($autocadLatest.tag_name -replace '^v',''); updateAvailable=(('v' + $autocad.version) -ne $autocadLatest.tag_name); url=$autocadLatest.html_url }
        )
        policy='A new upstream version is never activated until its lock hashes, security patch, build, MCP initialization, and schema diff pass.'
    } | ConvertTo-Json -Depth 8
    return
}

if ($Action -eq 'StageLocked') {
    if (Test-Path -LiteralPath $ArtifactsRoot) {
        throw "Staging target already exists: $ArtifactsRoot. Preserve or remove it before rebuilding."
    }
    if (-not $PSCmdlet.ShouldProcess($ArtifactsRoot, 'Build and verify locked provider candidates')) { return }
    & (Join-Path $SourceRoot 'providers\Build-Providers.ps1') -SourceRoot $SourceRoot -OutputRoot $ArtifactsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Locked provider staging failed.' }
    & (Join-Path $SourceRoot 'providers\Test-ProviderBundles.ps1') -SourceRoot $SourceRoot -ArtifactsRoot $ArtifactsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Locked provider smoke tests failed.' }
    return
}

if ($Action -eq 'Activate') {
    if (-not $PSCmdlet.ShouldProcess('AEC Codex providers', 'Activate staged versions')) { return }
    & (Join-Path $SourceRoot 'installer\Install-AecProviders.ps1') -Action Install -SourceRoot $SourceRoot -ArtifactsRoot $ArtifactsRoot -SkipBuild -Confirm:$false
    return
}

if ($Action -eq 'Rollback') {
    & (Join-Path $SourceRoot 'installer\Install-AecProviders.ps1') -Action Rollback -SourceRoot $SourceRoot -Confirm:$false
    return
}

if ($Action -eq 'Snapshot') {
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $config = Join-Path $local 'AEC Codex\providers\active.json'
    $snapshotRoot = Join-Path $local 'AEC Codex\providers\schemas'
    New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
    $previous = Get-ChildItem -LiteralPath $snapshotRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    $output = Join-Path $snapshotRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.json')
    $snapshotArgs = @((Join-Path $SourceRoot 'providers\Snapshot-ProviderSchemas.py'), '--config', $config, '--output', $output)
    if ($previous) { $snapshotArgs += @('--compare', $previous.FullName) }
    & python @snapshotArgs
    if ($LASTEXITCODE -ne 0) { throw 'Provider schema snapshot failed.' }
}
