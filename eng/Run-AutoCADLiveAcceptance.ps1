[CmdletBinding()]
param(
    [string]$Version = '2024',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [int]$TimeoutSeconds = 600,
    [switch]$BuildOnly,
    [switch]$AllowUnsigned,
    [switch]$IsolateCurrentUserPlugins
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($Version -ne '2024') {
    throw 'The current AutoCAD live-acceptance baseline supports only AutoCAD 2024.'
}
if ($TimeoutSeconds -lt 60 -or $TimeoutSeconds -gt 1800) {
    throw 'TimeoutSeconds must be from 60 through 1800.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD2024\BimBridge.AutoCAD2024.csproj'
$autocadExecutable = 'C:\Program Files\Autodesk\AutoCAD 2024\acad.exe'
$outputDirectory = Join-Path $repositoryRoot "src\BimBridge.AutoCAD2024\bin\$Configuration\net48"
$adapterAssembly = Join-Path $outputDirectory 'BimBridge.AutoCAD2024.dll'
$bridgeAssembly = Join-Path $outputDirectory 'BimBridge.Host.dll'
$driver = Join-Path $repositoryRoot 'tests\live\autocad_live_driver.py'
$mcpServer = Join-Path $repositoryRoot 'plugins\aec-codex\mcp-server\aec_mcp_server.py'
$signingScript = Join-Path $PSScriptRoot 'Sign-RevitLiveTestArtifacts.ps1'
$developmentTrustState = Join-Path $env:LOCALAPPDATA 'BIM Bridge\development-trust\revit-live-test-signing.json'

function Get-PrivatePython {
    foreach ($statePath in @(
        (Join-Path $env:LOCALAPPDATA 'BIM Bridge\install-state.json'),
        (Join-Path $env:LOCALAPPDATA 'AEC Codex\install-state.json')
    )) {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                foreach ($property in @('python','privatePython')) {
                    if ($state.PSObject.Properties[$property] -and (Test-Path -LiteralPath $state.$property -PathType Leaf)) {
                        return [string]$state.$property
                    }
                }
            } catch { }
        }
    }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) { return [string]$python.Source }
    throw 'No Python runtime is available for the BIM Bridge MCP host.'
}

function Get-SignatureEvidence([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    [ordered]@{
        path = $Path
        status = [string]$signature.Status
        statusMessage = [string]$signature.StatusMessage
        subject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { $null }
        thumbprint = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Thumbprint } else { $null }
    }
}

if (-not (Test-Path -LiteralPath $autocadExecutable -PathType Leaf)) {
    throw "AutoCAD 2024 executable was not found: $autocadExecutable"
}

& dotnet build $project -c $Configuration
if ($LASTEXITCODE -ne 0) { throw 'AutoCAD adapter build failed.' }

if (Test-Path -LiteralPath $developmentTrustState -PathType Leaf) {
    & $signingScript -Path @($adapterAssembly, $bridgeAssembly) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'AutoCAD live-test artifact signing failed.' }
}

$signatures = @((Get-SignatureEvidence $adapterAssembly), (Get-SignatureEvidence $bridgeAssembly))
$invalidSignatures = @($signatures | Where-Object { $_.status -ne 'Valid' })
if ($invalidSignatures.Count -gt 0 -and -not $AllowUnsigned) {
    throw 'AutoCAD live acceptance requires valid Authenticode signatures for the adapter and bridge assemblies.'
}

if ($BuildOnly) {
    [ordered]@{
        version = $Version
        status = 'built'
        targetFramework = 'net48'
        autocadExecutable = $autocadExecutable
        adapterAssembly = $adapterAssembly
        bridgeAssembly = $bridgeAssembly
        signatures = $signatures
    } | ConvertTo-Json -Depth 5
    exit 0
}

$sameVersionProcesses = @(Get-Process -Name 'acad' -ErrorAction SilentlyContinue | Where-Object {
    try { [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($autocadExecutable) } catch { $false }
})
if ($sameVersionProcesses.Count -gt 0) {
    throw 'AutoCAD 2024 is already running; refusing to mix a certification run with an existing session.'
}

$runId = [Guid]::NewGuid().ToString('N')
$certificationRoot = Join-Path $repositoryRoot 'artifacts\certification\autocad'
$runDirectory = Join-Path $certificationRoot "$Version\$runId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$reportPath = Join-Path $runDirectory 'report.json'
$startupScript = Join-Path $runDirectory 'load-test-adapter.scr'
$applicationPluginsRoot = Join-Path $env:APPDATA 'Autodesk\ApplicationPlugins'
$productionBundle = Join-Path $applicationPluginsRoot 'BIM Bridge.bundle'
$disabledBundle = $productionBundle + ".disabled-for-bim-bridge-live-$runId"

if ((Test-Path -LiteralPath $productionBundle) -and -not $IsolateCurrentUserPlugins) {
    $report = [ordered]@{
        schemaVersion = 1
        runId = $runId
        status = 'blocked'
        application = 'autocad'
        applicationVersion = $Version
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
        endedAtUtc = [DateTime]::UtcNow.ToString('o')
        runDirectory = $runDirectory
        failureCode = 'existing_bundle_conflict'
        failureMessage = 'The installed BIM Bridge AutoCAD bundle would make the loaded adapter ambiguous. Use -IsolateCurrentUserPlugins on a dedicated certification machine.'
        conflictingBundle = $productionBundle
        checks = @(@{ name='bundle_conflict'; passed=$false; message='Installed production bundle would contaminate the test adapter result.' })
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Write-Output ($report | ConvertTo-Json -Depth 20)
    throw "AutoCAD $Version live acceptance blocked by an installed bundle. Report: $reportPath"
}

$bundleMoved = $false
try {
    if (Test-Path -LiteralPath $productionBundle) {
        $expectedRoot = [IO.Path]::GetFullPath($applicationPluginsRoot).TrimEnd('\') + '\'
        foreach ($path in @($productionBundle, $disabledBundle)) {
            if (-not ([IO.Path]::GetFullPath($path).StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase))) {
                throw 'Calculated AutoCAD bundle path escaped the current-user ApplicationPlugins directory.'
            }
        }
        if (Test-Path -LiteralPath $disabledBundle) {
            throw "Refusing to overwrite an existing disabled AutoCAD bundle: $disabledBundle"
        }
        Move-Item -LiteralPath $productionBundle -Destination $disabledBundle
        $bundleMoved = $true
    }

    $netloadPath = $adapterAssembly.Replace('\', '/')
    $scriptText = "_.NETLOAD`r`n`"$netloadPath`"`r`n"
    [IO.File]::WriteAllText($startupScript, $scriptText, [Text.ASCIIEncoding]::new())

    $python = Get-PrivatePython
    & $python $driver `
        '--version' $Version `
        '--autocad-exe' $autocadExecutable `
        '--adapter-assembly' $adapterAssembly `
        '--mcp-server' $mcpServer `
        '--script' $startupScript `
        '--run-directory' $runDirectory `
        '--certification-root' $certificationRoot `
        '--run-id' $runId `
        '--timeout-seconds' ([string]$TimeoutSeconds)
    $driverExitCode = $LASTEXITCODE
    if (Test-Path -LiteralPath $reportPath) { Get-Content -LiteralPath $reportPath -Raw }
    if ($driverExitCode -ne 0) {
        throw "AutoCAD $Version live acceptance failed with exit code $driverExitCode. Report: $reportPath"
    }
} finally {
    if ($bundleMoved -and (Test-Path -LiteralPath $disabledBundle)) {
        if (Test-Path -LiteralPath $productionBundle) {
            throw "Cannot restore the temporarily disabled AutoCAD bundle because its original path is occupied: $productionBundle"
        }
        Move-Item -LiteralPath $disabledBundle -Destination $productionBundle
    }
}
