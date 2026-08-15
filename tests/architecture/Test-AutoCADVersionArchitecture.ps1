[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$matrixPath = Join-Path $repositoryRoot 'eng\Autodesk.Versions.props'
$matrixHelperPath = Join-Path $repositoryRoot 'eng\AutodeskVersionMatrix.ps1'
$projectPath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\BimBridge.AutoCAD.csproj'
$adapterPropertiesPath = Join-Path $repositoryRoot 'src\BimBridge.AutoCAD\BimBridge.AutoCAD.Adapter.props'
$buildScriptPath = Join-Path $repositoryRoot 'eng\Build-AutoCADAdapters.ps1'
$liveScriptPath = Join-Path $repositoryRoot 'eng\Run-AutoCADLiveAcceptance.ps1'
$installerPath = Join-Path $repositoryRoot 'installer\Install-BimBridge.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

. $matrixHelperPath
$entries = @(Get-AutoCADMatrixEntries $matrixPath)
$years = @($entries | ForEach-Object { $_.Include })
Assert-True (($years -join ',') -eq '2024,2025,2026,2027') "Unexpected AutoCAD matrix releases: $($years -join ',')"

foreach ($entry in $entries) {
    $year = [string]$entry.Include
    Assert-True ([string]$entry.AssemblyName -eq "BimBridge.AutoCAD$year") "AutoCAD $year has an invalid assembly identity."
    Assert-True (@('netfx','modern') -contains [string]$entry.RuntimeFamily) "AutoCAD $year has an invalid runtime family."
    Assert-True (@('fixed','installed-api-runtime') -contains [string]$entry.RuntimeResolution) "AutoCAD $year has an invalid runtime-resolution policy."
    Assert-True (@('codedom','roslyn') -contains [string]$entry.DynamicCompiler) "AutoCAD $year has an invalid dynamic compiler."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.SupportedTargetFrameworks)) "AutoCAD $year has no supported target frameworks."
    Assert-True ([string]$entry.Series -match '^R\d+\.\d+$') "AutoCAD $year has an invalid bundle series."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.InstallSubdirectory)) "AutoCAD $year has no install subdirectory."
}

$entryByYear = @{}
foreach ($entry in $entries) { $entryByYear[[string]$entry.Include] = $entry }
Assert-True ($entryByYear['2024'].RuntimeFamily -eq 'netfx' -and $entryByYear['2024'].DynamicCompiler -eq 'codedom') 'AutoCAD 2024 must preserve the certified .NET Framework/CodeDOM baseline.'
foreach ($year in @('2025','2026','2027')) {
    Assert-True ($entryByYear[$year].RuntimeFamily -eq 'modern' -and $entryByYear[$year].DynamicCompiler -eq 'roslyn') "AutoCAD $year must use the modern Roslyn runtime family."
    Assert-True ($entryByYear[$year].SupportStatus -eq 'implemented') "AutoCAD $year must be implemented after live certification."
}
Assert-True (@($entries | Where-Object { $_.CertificationStatus -eq 'certified' }).Count -eq 4) 'All four AutoCAD matrix variants must remain certified.'

$project = Get-Content -LiteralPath $projectPath -Raw
$adapterProperties = Get-Content -LiteralPath $adapterPropertiesPath -Raw
$buildScript = Get-Content -LiteralPath $buildScriptPath -Raw
$liveScript = Get-Content -LiteralPath $liveScriptPath -Raw
$installer = Get-Content -LiteralPath $installerPath -Raw
Assert-True ($project.Contains('BimBridge.AutoCAD.Adapter.props')) 'The shared AutoCAD project must import its adapter properties.'
Assert-True ($adapterProperties.Contains('Autodesk.Versions.props')) 'The AutoCAD adapter must import the single Autodesk matrix.'
Assert-True ($adapterProperties.Contains('Runtime\NetFramework\RuntimeCodeCompiler.cs')) 'The AutoCAD .NET Framework compiler boundary is missing.'
Assert-True ($adapterProperties.Contains('Runtime\Modern\RuntimeCodeCompiler.cs')) 'The AutoCAD modern compiler boundary is missing.'
Assert-True ($adapterProperties.Contains('Microsoft.CodeAnalysis.CSharp.dll')) 'Modern AutoCAD builds must bind to the exact host-shipped Roslyn compiler.'
Assert-True ($buildScript.Contains('AutodeskVersionMatrix.ps1')) 'The AutoCAD build must use the shared matrix resolver.'
Assert-True ($liveScript.Contains('AutodeskVersionMatrix.ps1')) 'AutoCAD live acceptance must use the shared matrix resolver.'
Assert-True (-not $liveScript.Contains("Version -ne '2024'")) 'AutoCAD live acceptance still hard-codes the 2024 baseline.'
Assert-True ($installer.Contains('Build-AutoCADAdapters.ps1')) 'The installer does not consume the shared AutoCAD build entry point.'
Assert-True ($installer.Contains('New-AutoCADPackageContents')) 'The installer does not generate matrix-scoped AutoCAD bundle components.'

$yearSpecificSources = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src') -Directory |
    Where-Object { $_.Name -match '^BimBridge\.AutoCAD\d{4}$' } |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.cs' -Recurse } |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' })
Assert-True ($yearSpecificSources.Count -eq 0) 'Year-specific AutoCAD business source files are not allowed.'

[ordered]@{
    status = 'passed'
    releases = $years
    sharedProject = $projectPath
} | ConvertTo-Json -Depth 3
