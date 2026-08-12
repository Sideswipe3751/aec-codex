[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$Version = '1.1.0-rc.2',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $SourceRoot 'artifacts\release' }

function Copy-ReleasePath([string]$RelativePath, [string]$StageRoot) {
    $source = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source)) { throw "Release input is missing: $source" }
    $destination = Join-Path $StageRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

& dotnet build (Join-Path $SourceRoot 'AEC.Codex.slnx') -c Release
if ($LASTEXITCODE -ne 0) { throw 'AEC Codex release build failed.' }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-release-' + [Guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $temporaryRoot 'aec-codex'
New-Item -ItemType Directory -Force -Path $stageRoot,$OutputDirectory | Out-Null
try {
    $providerArtifacts = Join-Path $SourceRoot 'artifacts\providers'
    $providerReady = $false
    if (Test-Path -LiteralPath (Join-Path $providerArtifacts 'build-manifest.json')) {
        try {
            & (Join-Path $SourceRoot 'providers\Test-ProviderBundles.ps1') -SourceRoot $SourceRoot -ArtifactsRoot $providerArtifacts
            $providerReady = $true
        } catch {
            Write-Warning ('Cached provider bundles are stale and will be rebuilt: ' + $_.Exception.Message)
        }
    }
    if (-not $providerReady) {
        $providerArtifacts = Join-Path $temporaryRoot 'provider-artifacts'
        & (Join-Path $SourceRoot 'providers\Build-Providers.ps1') -SourceRoot $SourceRoot -OutputRoot $providerArtifacts
        & (Join-Path $SourceRoot 'providers\Test-ProviderBundles.ps1') -SourceRoot $SourceRoot -ArtifactsRoot $providerArtifacts
    }
    if (-not (Test-Path -LiteralPath (Join-Path $providerArtifacts 'build-manifest.json'))) {
        throw 'Verified provider bundles are required for a release.'
    }

    foreach ($path in @(
        'LICENSE',
        'NOTICE',
        'README.md',
        'CHANGELOG.md',
        'SECURITY.md',
        'THIRD_PARTY_NOTICES.md',
        'installer\Install-AecCodex.ps1',
        'installer\Install-AecProviders.ps1',
        'installer\bootstrap.ps1',
        'plugins\aec-codex\.codex-plugin\plugin.json',
        'plugins\aec-codex\mcp-server',
        'plugins\aec-codex\providers\providers.lock.json',
        'providers',
        'src\Aec.Codex.Revit2024\Aec.Codex.Revit2024.addin',
        'src\Aec.Codex.Revit2024\bin\Release\net48',
        'src\Aec.Codex.AutoCAD2024\PackageContents.xml',
        'src\Aec.Codex.AutoCAD2024\bin\Release\net48'
    )) { Copy-ReleasePath $path $stageRoot }

    $providerStage = Join-Path $stageRoot 'artifacts\providers'
    New-Item -ItemType Directory -Force -Path $providerStage | Out-Null
    Get-ChildItem -LiteralPath $providerArtifacts -Force |
        Copy-Item -Destination $providerStage -Recurse -Force

    # Provider verification uses the npm CLI before staging. The installed
    # Revit child server only needs node.exe, so strip the package-manager tree
    # from the release payload. This removes thousands of unused files,
    # including npm's empty .npmrc, without changing the verified server tree.
    foreach ($nodeRoot in @(Get-ChildItem -LiteralPath (Join-Path $providerStage 'revit-community') -Directory -Recurse |
            Where-Object { $_.FullName -match '[\\/]runtime[\\/]node$' })) {
        $nodeExe = Join-Path $nodeRoot.FullName 'node.exe'
        $nodeLicense = Join-Path $nodeRoot.FullName 'LICENSE'
        if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf) -or -not (Test-Path -LiteralPath $nodeLicense -PathType Leaf)) {
            throw "Verified Node runtime is incomplete: $($nodeRoot.FullName)"
        }
        $minimalRoot = Join-Path $nodeRoot.Parent.FullName ('node-minimal-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $minimalRoot | Out-Null
        Copy-Item -LiteralPath $nodeExe,$nodeLicense -Destination $minimalRoot -Force
        $resolvedNodeRoot = [IO.Path]::GetFullPath($nodeRoot.FullName)
        $resolvedProviderStage = [IO.Path]::GetFullPath($providerStage)
        if (-not $resolvedNodeRoot.StartsWith($resolvedProviderStage, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe Node runtime trim target: $resolvedNodeRoot"
        }
        Remove-Item -LiteralPath $resolvedNodeRoot -Recurse -Force
        Move-Item -LiteralPath $minimalRoot -Destination $resolvedNodeRoot
    }

    foreach ($required in @(
        'installer\Install-AecCodex.ps1',
        'plugins\aec-codex\.codex-plugin\plugin.json',
        'plugins\aec-codex\mcp-server\aec_mcp_server.py',
        'artifacts\providers\build-manifest.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $stageRoot $required) -PathType Leaf)) {
            throw "Host payload is missing required file: $required"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $stageRoot 'plugins\aec-codex\release-manifest.json')) {
        throw 'Host payload must not contain the self-pinning release manifest.'
    }
    $forbidden = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Force | Where-Object {
        $_.Name -match '^(\.env|\.npmrc|id_rsa|credentials)$' -or $_.Extension -match '^\.(pem|key|pfx|p12)$'
    })
    if ($forbidden.Count -gt 0) {
        throw ('Host payload contains forbidden files: ' + (($forbidden | Select-Object -ExpandProperty FullName) -join ', '))
    }

    # This is a host-only payload. In particular, it excludes the plugin's
    # release-manifest.json so the payload SHA-256 can be pinned by that
    # manifest without creating a self-referential archive hash.
    $zipName = "aec-codex-host-$Version-win-x64.zip"
    $zipPath = Join-Path $OutputDirectory $zipName
    if (Test-Path -LiteralPath $zipPath) { throw "Release output already exists: $zipPath" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stageRoot,
        $zipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipPath + '.sha256', ($hash + '  ' + $zipName + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    Write-Host "Release: $zipPath"
    Write-Host "SHA-256: $hash"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe release cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
