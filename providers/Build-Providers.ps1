[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent $scriptDirectory
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $SourceRoot 'artifacts\providers' }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Download-Verified([string]$Url, [string]$Sha256, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Destination)) {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256.ToLowerInvariant()) {
        throw "Checksum mismatch for $Url. Expected $Sha256, received $actual."
    }
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

$lockPath = Join-Path $SourceRoot 'plugins\aec-codex\providers\providers.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$revit = $lock.providers | Where-Object { $_.id -eq 'revit-community' }
$autocad = $lock.providers | Where-Object { $_.id -eq 'autocad-pro' }
if (-not $revit -or -not $autocad) { throw 'Provider lock is incomplete.' }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-provider-build-' + [Guid]::NewGuid().ToString('N'))
$downloads = Join-Path $temporaryRoot 'downloads'
$buildRoot = Join-Path $temporaryRoot 'build'
New-Item -ItemType Directory -Force -Path $downloads,$buildRoot,$OutputRoot | Out-Null

try {
    $revitSourceZip = Join-Path $downloads 'revit-source.zip'
    Download-Verified $revit.source.url $revit.source.sha256 $revitSourceZip
    $revitSourceParent = Join-Path $buildRoot 'revit-source'
    Expand-Archive -LiteralPath $revitSourceZip -DestinationPath $revitSourceParent -Force
    $revitSource = (Get-ChildItem -LiteralPath $revitSourceParent -Directory | Select-Object -First 1).FullName
    $securityPatch = Join-Path $SourceRoot 'providers\patches\revit-community-v1.0.0-security.patch'
    & git -C $revitSource apply --check $securityPatch
    if ($LASTEXITCODE -ne 0) { throw 'The Revit provider security patch no longer applies.' }
    & git -C $revitSource apply $securityPatch
    if ($LASTEXITCODE -ne 0) { throw 'Unable to apply the Revit provider security patch.' }

    & dotnet build (Join-Path $revitSource 'plugin\RevitMCPPlugin.csproj') -c 'Release R24'
    if ($LASTEXITCODE -ne 0) { throw 'Revit provider plugin build failed.' }
    # Nice3point's publish target expects localized Roslyn resource assemblies that
    # are not present in every SDK layout. We only need the compiled command set;
    # our own packaging step below handles deployment deterministically.
    & dotnet build (Join-Path $revitSource 'commandset\RevitMCPCommandSet.csproj') -c 'Release R24' -p:PublishAddinFiles=false
    if ($LASTEXITCODE -ne 0) { throw 'Revit provider command-set build failed.' }

    $revitOutput = Join-Path $OutputRoot ('revit-community\' + $revit.version)
    if (Test-Path -LiteralPath $revitOutput) {
        throw "Provider output already exists: $revitOutput. Move it aside before rebuilding."
    }
    $addinOutput = Join-Path $revitOutput 'addin'
    $pluginOutput = Join-Path $addinOutput 'revit_mcp_plugin'
    $commandOutput = Join-Path $pluginOutput 'Commands\RevitMCPCommandSet\2024'
    New-Item -ItemType Directory -Force -Path $commandOutput | Out-Null

    # Assemble a canonical package from compiler outputs. The upstream AddIn
    # staging folder is intentionally avoided because its publish targets can
    # leave partially materialized recursive paths on some Windows SDKs.
    Copy-Item -LiteralPath (Join-Path $revitSource 'plugin\mcp-servers-for-revit.addin') -Destination $addinOutput
    Get-ChildItem -LiteralPath (Join-Path $revitSource 'plugin\bin\Release\2024') -File |
        Where-Object { $_.Extension -in '.dll', '.pdb' } |
        Copy-Item -Destination $pluginOutput -Force
    Get-ChildItem -LiteralPath (Join-Path $revitSource 'commandset\bin\Release R24') -File |
        Where-Object { $_.Extension -in '.dll', '.pdb' } |
        Copy-Item -Destination $commandOutput -Force
    $commandTemplate = Join-Path $revitSource 'command.json'
    Copy-Item -LiteralPath $commandTemplate -Destination (Split-Path -Parent $commandOutput) -Force
    $commandRegistry = Get-Content -LiteralPath $commandTemplate -Raw | ConvertFrom-Json
    foreach ($command in $commandRegistry.commands) {
        $command.assemblyPath = 'RevitMCPCommandSet\{VERSION}\RevitMCPCommandSet.dll'
    }
    Write-Utf8NoBom (Join-Path $pluginOutput 'Commands\commandRegistry.json') ($commandRegistry | ConvertTo-Json -Depth 10)

    $node = $lock.runtimes.'node-windows-x64'
    $nodeZip = Join-Path $downloads 'node.zip'
    Download-Verified $node.url $node.sha256 $nodeZip
    $nodeParent = Join-Path $buildRoot 'node'
    Expand-Archive -LiteralPath $nodeZip -DestinationPath $nodeParent -Force
    $nodeSource = (Get-ChildItem -LiteralPath $nodeParent -Directory | Select-Object -First 1).FullName
    Copy-DirectoryContents $nodeSource (Join-Path $revitOutput 'runtime\node')

    # Install the dependency tree outside OneDrive. Native package installers
    # create thousands of short-lived files and must also be able to resolve the
    # bundled node.exe from PATH.
    $serverBuild = Join-Path $buildRoot 'revit-server'
    Copy-DirectoryContents (Join-Path $revitSource 'server') $serverBuild
    $dependencyAuditPatch = Join-Path $SourceRoot 'providers\patches\revit-community-v1.0.0-dependency-audit.patch'
    & git -C $serverBuild apply --check $dependencyAuditPatch
    if ($LASTEXITCODE -ne 0) { throw 'The Revit provider dependency audit patch no longer applies.' }
    & git -C $serverBuild apply $dependencyAuditPatch
    if ($LASTEXITCODE -ne 0) { throw 'Unable to apply the Revit provider dependency audit patch.' }
    $npm = Join-Path $nodeSource 'npm.cmd'
    $originalPath = $env:PATH
    try {
        $env:PATH = $nodeSource + [IO.Path]::PathSeparator + $originalPath
        & $npm ci --prefix $serverBuild --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Locked Revit MCP dependency installation failed.' }
        & $npm run --prefix $serverBuild build
        if ($LASTEXITCODE -ne 0) { throw 'Revit MCP TypeScript build failed.' }
        & $npm prune --prefix $serverBuild --omit=dev --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Revit MCP runtime dependency pruning failed.' }
    } finally {
        $env:PATH = $originalPath
    }
    $utilsRoot = Join-Path $serverBuild 'build\utils'
    $socketClient = Join-Path $utilsRoot 'SocketClient.js'
    $connectionManager = Join-Path $utilsRoot 'ConnectionManager.js'
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'providers\patches\SocketClient.secure.js') -Destination $socketClient -Force
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'providers\patches\ConnectionManager.secure.js') -Destination $connectionManager -Force
    & (Join-Path $nodeSource 'node.exe') --check $socketClient
    if ($LASTEXITCODE -ne 0) { throw 'Secured Revit SocketClient did not pass syntax validation.' }
    & (Join-Path $nodeSource 'node.exe') --check $connectionManager
    if ($LASTEXITCODE -ne 0) { throw 'Secured Revit ConnectionManager did not pass syntax validation.' }
    Copy-DirectoryContents $serverBuild (Join-Path $revitOutput 'server')
    Copy-Item -LiteralPath (Join-Path $revitSource 'LICENSE') -Destination (Join-Path $revitOutput 'LICENSE')

    $wheel = Join-Path $downloads 'autocad-provider.whl'
    Download-Verified $autocad.wheel.url $autocad.wheel.sha256 $wheel
    $autocadOutput = Join-Path $OutputRoot ('autocad-pro\' + $autocad.version)
    if (Test-Path -LiteralPath $autocadOutput) {
        throw "Provider output already exists: $autocadOutput. Move it aside before rebuilding."
    }
    New-Item -ItemType Directory -Force -Path $autocadOutput | Out-Null
    $wheelName = [IO.Path]::GetFileName(([Uri]$autocad.wheel.url).AbsolutePath)
    $patchedWheel = Join-Path $autocadOutput $wheelName
    Copy-Item -LiteralPath $wheel -Destination $patchedWheel
    & python (Join-Path $SourceRoot 'providers\Patch-AutoCADWheel.py') $patchedWheel
    if ($LASTEXITCODE -ne 0) { throw 'Unable to apply the AutoCAD provider COM fixes.' }
    $licenseUrl = $autocad.repository + '/raw/' + $autocad.tag + '/LICENSE'
    Invoke-WebRequest -Uri $licenseUrl -OutFile (Join-Path $autocadOutput 'LICENSE') -UseBasicParsing

    [ordered]@{
        schemaVersion = 1
        builtAtUtc = [DateTime]::UtcNow.ToString('o')
        providers = @(
            [ordered]@{
                id='revit-community'; version=$revit.version; sourceCommit=$revit.commit
                dependencyPatch='revit-community-v1.0.0-dependency-audit-2026-08-11'
            },
            [ordered]@{
                id='autocad-pro'; version=$autocad.version; sourceTag=$autocad.tag
                patch='autocad-pro-v1.5.1-live-com-fixes-v2'
            }
        )
    } | ConvertTo-Json -Depth 8 | ForEach-Object {
        Write-Utf8NoBom (Join-Path $OutputRoot 'build-manifest.json') $_
    }
    Write-Host "Provider bundles built at $OutputRoot"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe temporary cleanup target: $resolved"
        }
        # Cleanup must not hide the actual build result if an upstream build leaves
        # behind a broken publish link or another transient filesystem entry.
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
