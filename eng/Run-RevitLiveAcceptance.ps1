[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [int]$TimeoutSeconds = 600,
    [string]$TemplatePath,
    [switch]$BuildOnly,
    [switch]$AllowUnsigned,
    [switch]$TemporarilyDisableConflictingManifests,
    [switch]$IsolateCurrentUserAddins
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$matrixPath = Join-Path $PSScriptRoot 'Autodesk.Versions.props'
$adapterBuildScript = Join-Path $PSScriptRoot 'Build-RevitAdapters.ps1'
$bootstrapProject = Join-Path $repositoryRoot 'tests\revit\BimBridge.Revit.TestBootstrap\BimBridge.Revit.TestBootstrap.csproj'
$bootstrapTemplate = Join-Path $repositoryRoot 'tests\revit\BimBridge.Revit.TestBootstrap\BimBridge.Revit.TestBootstrap.addin.template'
$driverProject = Join-Path $repositoryRoot 'tests\live\BimBridge.LiveTestDriver\BimBridge.LiveTestDriver.csproj'
$mcpServer = Join-Path $repositoryRoot 'plugins\aec-codex\mcp-server\aec_mcp_server.py'
$signingScript = Join-Path $PSScriptRoot 'Sign-RevitLiveTestArtifacts.ps1'
$matrixHelperPath = Join-Path $PSScriptRoot 'RevitVersionMatrix.ps1'
. $matrixHelperPath

function Write-JsonFile([string]$Path, [object]$Value) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

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

if ($TimeoutSeconds -lt 60 -or $TimeoutSeconds -gt 1800) {
    throw 'TimeoutSeconds must be from 60 through 1800.'
}

$entries = @(Get-RevitMatrixEntries $matrixPath)
$matches = @($entries | Where-Object { [string]$_.Include -eq $Version })
if ($matches.Count -ne 1) { throw "Unknown or duplicate Revit release in matrix: $Version" }
$release = Resolve-RevitMatrixEntry $matches[0]
$targetFramework = [string]$release.TargetFramework
$runtimeFamily = [string]$release.RuntimeFamily
$installDirectory = $release.InstallDirectory
$revitExecutable = $release.RevitExecutable
if (-not $TemplatePath) {
    $TemplatePath = $release.DefaultTemplate
}
$TemplatePath = [IO.Path]::GetFullPath($TemplatePath)
if (-not (Test-Path -LiteralPath $revitExecutable -PathType Leaf)) { throw "Revit $Version executable was not found: $revitExecutable" }
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { throw "Revit $Version template was not found: $TemplatePath" }

& $adapterBuildScript -Version $Version -Configuration $Configuration
if ($LASTEXITCODE -ne 0) { throw "Revit $Version adapter build failed." }

$bootstrapArguments = @(
    'build', $bootstrapProject,
    '--nologo', '-v:minimal', '-clp:ErrorsOnly',
    '-c', $Configuration,
    "-p:RevitVersion=$Version",
    "-p:RevitTargetFramework=$targetFramework",
    "-p:RevitInstallDir=$installDirectory",
    "-p:BaseIntermediateOutputPath=obj\$Version\",
    "-p:MSBuildProjectExtensionsPath=obj\$Version\"
)
& dotnet @bootstrapArguments
if ($LASTEXITCODE -ne 0) { throw "Revit $Version live-test bootstrap build failed." }

& dotnet build $driverProject -c $Configuration --nologo -v:minimal -clp:ErrorsOnly
if ($LASTEXITCODE -ne 0) { throw 'Live-test driver build failed.' }

$adapterDirectory = Join-Path $repositoryRoot "src\BimBridge.Revit\bin\$Configuration\$Version\$targetFramework"
$adapterAssembly = Join-Path $adapterDirectory "$($release.AssemblyName).dll"
$adapterManifest = Join-Path $adapterDirectory $release.ManifestName
$bootstrapDirectory = Join-Path $repositoryRoot "tests\revit\BimBridge.Revit.TestBootstrap\bin\$Configuration\$Version\$targetFramework"
$bootstrapAssembly = Join-Path $bootstrapDirectory "BimBridge.Revit.TestBootstrap$Version.dll"
$driverAssembly = Join-Path $repositoryRoot "tests\live\BimBridge.LiveTestDriver\bin\$Configuration\net10.0-windows\BimBridge.LiveTestDriver.dll"
foreach ($requiredPath in @($adapterAssembly, $adapterManifest, $bootstrapAssembly, $driverAssembly, $mcpServer)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Expected live-test artifact was not produced: $requiredPath" }
}

$manifestSettings = ''
if ([string]$release.UseRevitContext -eq 'false' -and $runtimeFamily -ne 'netfx') {
    $manifestSettings = @"
  <ManifestSettings>
    <UseRevitContext>False</UseRevitContext>
    <ContextName>BIM.Bridge.LiveTest</ContextName>
  </ManifestSettings>
"@
}
$bootstrapManifestContent = (Get-Content -LiteralPath $bootstrapTemplate -Raw).
    Replace('{{ASSEMBLY_PATH}}', $bootstrapAssembly).
    Replace('{{MANIFEST_SETTINGS}}', $manifestSettings.TrimEnd())
$bootstrapManifest = Join-Path $bootstrapDirectory "BimBridge.Revit.TestBootstrap$Version.addin"
[IO.File]::WriteAllText($bootstrapManifest, $bootstrapManifestContent, [Text.UTF8Encoding]::new($false))

$developmentTrustState = Join-Path $env:LOCALAPPDATA 'BIM Bridge\development-trust\revit-live-test-signing.json'
if (Test-Path -LiteralPath $developmentTrustState -PathType Leaf) {
    & $signingScript -Path @($adapterAssembly, $bootstrapAssembly) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Revit live-test artifact signing failed.' }
}

if ($BuildOnly) {
    [ordered]@{
        version = $Version
        status = 'built'
        runtimeFamily = $runtimeFamily
        targetFramework = $targetFramework
        runtimeResolution = $release.RuntimeResolution
        detectedRuntime = $release.DetectedRuntime
        revitExecutable = $revitExecutable
        template = $TemplatePath
        adapterAssembly = $adapterAssembly
        adapterManifest = $adapterManifest
        bootstrapAssembly = $bootstrapAssembly
        bootstrapManifest = $bootstrapManifest
        driverAssembly = $driverAssembly
        signatures = @((Get-SignatureEvidence $adapterAssembly), (Get-SignatureEvidence $bootstrapAssembly))
    } | ConvertTo-Json -Depth 5
    exit 0
}

$runId = [Guid]::NewGuid().ToString('N')
$tokenBytes = New-Object byte[] 32
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $random.GetBytes($tokenBytes) } finally { $random.Dispose() }
$token = [Convert]::ToBase64String($tokenBytes)
$certificationRoot = Join-Path $repositoryRoot 'artifacts\certification\revit'
$runDirectory = Join-Path $certificationRoot "$Version\$runId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$reportPath = Join-Path $runDirectory 'report.json'
$signatures = @(
    (Get-SignatureEvidence $adapterAssembly),
    (Get-SignatureEvidence $bootstrapAssembly)
)
$invalidSignatures = @($signatures | Where-Object { $_.status -ne 'Valid' })
if ($invalidSignatures.Count -gt 0 -and -not $AllowUnsigned) {
    $report = [ordered]@{
        schemaVersion = 1
        runId = $runId
        status = 'blocked'
        revitVersion = $Version
        runtimeFamily = $runtimeFamily
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
        endedAtUtc = [DateTime]::UtcNow.ToString('o')
        runDirectory = $runDirectory
        failureCode = 'untrusted_binary'
        failureMessage = 'Live acceptance did not launch Revit because one or more test add-ins lack a valid Authenticode signature. Sign and trust the development assemblies, or use -AllowUnsigned only on a machine whose Revit trust policy is already configured for them.'
        signatures = $signatures
        checks = @(@{ name='addin_trust'; passed=$false; message='Unsigned or invalid add-in binaries were rejected before launch.' })
    }
    Write-JsonFile $reportPath $report
    Write-Output ($report | ConvertTo-Json -Depth 20)
    throw "Revit $Version live acceptance blocked by add-in trust. Report: $reportPath"
}

$activeManifestConflicts = @()
$currentUserManifestRoot = Join-Path $env:APPDATA "Autodesk\Revit\Addins\$Version"
foreach ($manifestRoot in @(
    $currentUserManifestRoot,
    (Join-Path $env:ProgramData "Autodesk\Revit\Addins\$Version")
)) {
    if (Test-Path -LiteralPath $manifestRoot -PathType Container) {
        $activeManifestConflicts += @(Get-ChildItem -LiteralPath $manifestRoot -File -Filter '*.addin' -ErrorAction SilentlyContinue |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '66E6F0BE-A5B5-49D8-A543-EBF53885A58D' } |
            ForEach-Object { $_.FullName })
    }
}
$activeManifestConflicts = @($activeManifestConflicts | Select-Object -Unique)
$manifestsToDisable = @()
if ($TemporarilyDisableConflictingManifests) {
    $manifestsToDisable += $activeManifestConflicts
}
if ($IsolateCurrentUserAddins -and (Test-Path -LiteralPath $currentUserManifestRoot -PathType Container)) {
    $manifestsToDisable += @(Get-ChildItem -LiteralPath $currentUserManifestRoot -File -Filter '*.addin' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
}
$manifestsToDisable = @($manifestsToDisable | Select-Object -Unique)
$unmitigatedManifestConflicts = @($activeManifestConflicts | Where-Object { $manifestsToDisable -notcontains $_ })
if ($unmitigatedManifestConflicts.Count -gt 0) {
    $report = [ordered]@{
        schemaVersion = 1
        runId = $runId
        status = 'blocked'
        revitVersion = $Version
        runtimeFamily = $runtimeFamily
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
        endedAtUtc = [DateTime]::UtcNow.ToString('o')
        runDirectory = $runDirectory
        failureCode = 'existing_addin_conflict'
        failureMessage = 'An active BIM Bridge manifest already owns the production add-in ID. Disable that exact manifest before certification so Revit cannot load two connector assemblies.'
        conflictingManifests = $unmitigatedManifestConflicts
        checks = @(@{ name='manifest_conflict'; passed=$false; message='Existing production connector manifest would make the test artifact ambiguous.' })
    }
    Write-JsonFile $reportPath $report
    Write-Output ($report | ConvertTo-Json -Depth 20)
    throw "Revit $Version live acceptance blocked by an existing connector manifest. Report: $reportPath"
}

$addinsDirectory = Join-Path $env:APPDATA "Autodesk\Revit\Addins\$Version"
New-Item -ItemType Directory -Path $addinsDirectory -Force | Out-Null
$connectorDeployment = Join-Path $addinsDirectory "BIM-Bridge-Live-$runId-Connector.addin"
$bootstrapDeployment = Join-Path $addinsDirectory "BIM-Bridge-Live-$runId-Bootstrap.addin"
$disabledManifestMoves = @()
$expectedRoot = [IO.Path]::GetFullPath($addinsDirectory).TrimEnd('\') + '\'
foreach ($deployment in @($connectorDeployment, $bootstrapDeployment)) {
    if (-not ([IO.Path]::GetFullPath($deployment).StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Calculated deployment path escaped the version-specific Revit Addins directory.'
    }
}

try {
    foreach ($manifest in $manifestsToDisable) {
        $disabledPath = $manifest + ".disabled-for-bim-bridge-live-$runId"
        if (Test-Path -LiteralPath $disabledPath) {
            throw "Refusing to overwrite an existing disabled manifest: $disabledPath"
        }
        Move-Item -LiteralPath $manifest -Destination $disabledPath
        $disabledManifestMoves += [pscustomobject]@{
            Original = $manifest
            Disabled = $disabledPath
        }
    }
    Copy-Item -LiteralPath $adapterManifest -Destination $connectorDeployment
    Copy-Item -LiteralPath $bootstrapManifest -Destination $bootstrapDeployment
    $python = Get-PrivatePython
    $driverArguments = @(
        $driverAssembly,
        '--version', $Version,
        '--runtime-family', $runtimeFamily,
        '--revit-exe', $revitExecutable,
        '--template', $TemplatePath,
        '--adapter-assembly', $adapterAssembly,
        '--bootstrap-assembly', $bootstrapAssembly,
        '--mcp-server', $mcpServer,
        '--python', $python,
        '--run-directory', $runDirectory,
        '--certification-root', $certificationRoot,
        '--run-id', $runId,
        '--token', $token,
        '--timeout-seconds', [string]$TimeoutSeconds
    )
    & dotnet @driverArguments
    $driverExitCode = $LASTEXITCODE
    if (Test-Path -LiteralPath $reportPath) { Get-Content -LiteralPath $reportPath -Raw }
    if ($driverExitCode -ne 0) { throw "Revit $Version live acceptance failed with exit code $driverExitCode. Report: $reportPath" }
} finally {
    foreach ($deployment in @($connectorDeployment, $bootstrapDeployment)) {
        if (Test-Path -LiteralPath $deployment -PathType Leaf) { Remove-Item -LiteralPath $deployment -Force }
    }
    foreach ($move in @($disabledManifestMoves)) {
        if (Test-Path -LiteralPath $move.Disabled -PathType Leaf) {
            if (Test-Path -LiteralPath $move.Original) {
                throw "Cannot restore the temporarily disabled manifest because its original path is occupied: $($move.Original)"
            }
            Move-Item -LiteralPath $move.Disabled -Destination $move.Original
        }
    }
}
