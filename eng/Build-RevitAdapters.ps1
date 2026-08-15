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
$projectPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.csproj'
$templatePath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.addin.template'
$matrixHelperPath = Join-Path $PSScriptRoot 'RevitVersionMatrix.ps1'
. $matrixHelperPath

$releases = @(Get-RevitMatrixEntries $matrixPath)
if (-not $Version -or $Version.Count -eq 0) {
    $Version = @($releases | ForEach-Object { [string]$_.Include })
}

$results = New-Object System.Collections.ArrayList
foreach ($year in $Version) {
    $release = @($releases | Where-Object { [string]$_.Include -eq [string]$year })
    if ($release.Count -ne 1) { throw "Unknown or duplicate Revit release in matrix: $year" }
    $release = Resolve-RevitMatrixEntry $release[0]

    $targetFramework = $release.TargetFramework
    $installDir = $release.InstallDirectory
    $apiPath = $release.ApiPath
    if (-not (Test-Path -LiteralPath $apiPath -PathType Leaf)) {
        if ($SkipUnavailable) {
            [void]$results.Add([ordered]@{ version=$year; status='skipped'; reason='Revit API not installed' })
            continue
        }
        throw "Revit $year API was not found: $apiPath"
    }

    $arguments = @(
        'build', $projectPath,
        '--nologo', '-v:minimal', '-clp:ErrorsOnly',
        '-c', $Configuration,
        "-p:RevitVersion=$year",
        "-p:RevitTargetFramework=$targetFramework",
        "-p:RevitInstallDir=$installDir",
        "-p:BaseIntermediateOutputPath=obj\$year\",
        "-p:MSBuildProjectExtensionsPath=obj\$year\"
    )
    if ($NoRestore) { $arguments += '--no-restore' }
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw "Revit $year adapter build failed." }

    $outputDirectory = Join-Path $repositoryRoot "src\BimBridge.Revit\bin\$Configuration\$year\$targetFramework"
    $assemblyName = "$($release.AssemblyName).dll"
    $assemblyPath = Join-Path $outputDirectory $assemblyName
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw "Expected Revit $year adapter output was not produced: $assemblyPath"
    }

    $manifestSettings = ''
    if ($release.UseRevitContext -eq 'false' -and $release.RuntimeFamily -ne 'netfx') {
        $manifestSettings = @"
  <ManifestSettings>
    <UseRevitContext>False</UseRevitContext>
    <ContextName>BIM.Bridge</ContextName>
  </ManifestSettings>
"@
    }
    $manifest = (Get-Content -LiteralPath $templatePath -Raw).
        Replace('{{ASSEMBLY_PATH}}', $assemblyPath).
        Replace('{{MANIFEST_SETTINGS}}', $manifestSettings.TrimEnd())
    $manifestPath = Join-Path $outputDirectory $release.ManifestName
    [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))

    [void]$results.Add([ordered]@{
        version = $year
        status = 'built'
        targetFramework = $targetFramework
        runtimeFamily = $release.RuntimeFamily
        runtimeResolution = $release.RuntimeResolution
        detectedRuntime = $release.DetectedRuntime
        supportStatus = $release.SupportStatus
        certificationStatus = $release.CertificationStatus
        assembly = $assemblyPath
        manifest = $manifestPath
    })
}

@($results) | ConvertTo-Json -Depth 5
