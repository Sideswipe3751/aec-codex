[CmdletBinding()]
param(
    [string[]]$Version,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$SkipUnavailable,
    [switch]$NoRestore
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$matrixPath = Join-Path $PSScriptRoot 'Autodesk.Versions.props'
$projectPath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\BimBridge.AutoCAD.csproj'
. (Join-Path $PSScriptRoot 'AutodeskVersionMatrix.ps1')

$releases = @(Get-AutoCADMatrixEntries $matrixPath)
if (-not $Version -or $Version.Count -eq 0) {
    $Version = @($releases | ForEach-Object { [string]$_.Include })
}

$results = New-Object System.Collections.ArrayList
foreach ($year in $Version) {
    $release = @($releases | Where-Object { [string]$_.Include -eq [string]$year })
    if ($release.Count -ne 1) { throw "Unknown or duplicate AutoCAD release in matrix: $year" }
    try {
        $release = Resolve-AutoCADMatrixEntry $release[0]
    } catch {
        if ($SkipUnavailable) {
            [void]$results.Add([ordered]@{ version=$year; status='skipped'; reason=$_.Exception.Message })
            continue
        }
        throw
    }

    if (-not (Test-Path -LiteralPath $release.ApiPath -PathType Leaf)) {
        if ($SkipUnavailable) {
            [void]$results.Add([ordered]@{ version=$year; status='skipped'; reason='AutoCAD managed API not installed' })
            continue
        }
        throw "AutoCAD $year managed API was not found: $($release.ApiPath)"
    }

    $arguments = @(
        'build', $projectPath,
        '--nologo', '-v:minimal', '-clp:ErrorsOnly',
        '-c', $Configuration,
        "-p:AutoCADVersion=$year",
        "-p:AutoCADTargetFramework=$($release.TargetFramework)",
        "-p:AutoCADInstallDir=$($release.InstallDirectory)",
        "-p:BaseIntermediateOutputPath=obj\$year\",
        "-p:MSBuildProjectExtensionsPath=obj\$year\"
    )
    if ($NoRestore) { $arguments += '--no-restore' }
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw "AutoCAD $year adapter build failed." }

    $outputDirectory = Join-Path $repositoryRoot "src\BimBridge.AutoCAD\bin\$Configuration\$year\$($release.TargetFramework)"
    $assemblyPath = Join-Path $outputDirectory "$($release.AssemblyName).dll"
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw "Expected AutoCAD $year adapter output was not produced: $assemblyPath"
    }

    [void]$results.Add([ordered]@{
        version = $year
        status = 'built'
        targetFramework = $release.TargetFramework
        runtimeFamily = $release.RuntimeFamily
        runtimeResolution = $release.RuntimeResolution
        detectedRuntime = $release.DetectedRuntime
        dynamicCompiler = $release.DynamicCompiler
        supportStatus = $release.SupportStatus
        certificationStatus = $release.CertificationStatus
        assembly = $assemblyPath
    })
}

@($results) | ConvertTo-Json -Depth 5
