$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$matrixPath = Join-Path $repositoryRoot 'eng\Autodesk.Versions.props'
$projectPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.csproj'
$templatePath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.addin.template'
$buildScriptPath = Join-Path $repositoryRoot 'eng\Build-RevitAdapters.ps1'
$matrixHelperPath = Join-Path $repositoryRoot 'eng\RevitVersionMatrix.ps1'
$liveScriptPath = Join-Path $repositoryRoot 'eng\Run-RevitLiveAcceptance.ps1'
$bootstrapProjectPath = Join-Path $repositoryRoot 'tests\revit\BimBridge.Revit.TestBootstrap\BimBridge.Revit.TestBootstrap.csproj'
$bootstrapSourcePath = Join-Path $repositoryRoot 'tests\revit\BimBridge.Revit.TestBootstrap\LiveTestBootstrapApplication.cs'
$liveDriverPath = Join-Path $repositoryRoot 'tests\live\BimBridge.LiveTestDriver\Program.cs'
$trustScriptPath = Join-Path $repositoryRoot 'eng\Initialize-RevitLiveTestTrust.ps1'
$signingScriptPath = Join-Path $repositoryRoot 'eng\Sign-RevitLiveTestArtifacts.ps1'
$revitExecutorPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\RevitConnectorExecutor.cs'
$revitFailurePreprocessorPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\RevitFailurePreprocessor.cs'
$revitViewCapturePath = Join-Path $repositoryRoot 'src\BimBridge.Revit\RevitViewCaptureService.cs'
$connectorServerPath = Join-Path $repositoryRoot 'src\BimBridge.Host\ConnectorServer.cs'
$runtimeCapabilitiesPath = Join-Path $repositoryRoot 'runtime\aec_runtime\capabilities.py'
$runtimeServicePath = Join-Path $repositoryRoot 'runtime\aec_runtime\service.py'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

[xml]$matrix = Get-Content -LiteralPath $matrixPath -Raw
$entries = @($matrix.Project.Choose.When | ForEach-Object { $_.PropertyGroup })
Assert-True ($entries.Count -gt 0) 'The Revit version matrix is empty.'

$years = @($entries | ForEach-Object { [string]$_.ReleaseYear })
Assert-True (@($years | Where-Object { -not $_ }).Count -eq 0) 'Every matrix entry must declare ReleaseYear.'
Assert-True (@($years | Sort-Object -Unique).Count -eq $years.Count) 'Revit ReleaseYear values must be unique.'

foreach ($entry in $entries) {
    $year = [string]$entry.ReleaseYear
    Assert-True ([string]$entry.RevitAssemblyName -eq "BimBridge.Revit$year") "Revit $year assembly identity is not BIM Bridge branded."
    Assert-True ([string]$entry.RevitManifestName -eq "BimBridge.Revit$year.addin") "Revit $year generated manifest is not BIM Bridge branded."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitTargetFramework)) "Revit $year is missing RevitTargetFramework."
    Assert-True (@('netfx', 'modern') -contains [string]$entry.RevitRuntimeFamily) "Revit $year has an invalid runtime family."
    Assert-True (@('fixed', 'installed-api-runtime') -contains [string]$entry.RevitRuntimeResolution) "Revit $year has an invalid runtime-resolution policy."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitSupportedTargetFrameworks)) "Revit $year is missing supported target frameworks."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitInstallSubdirectory)) "Revit $year is missing its install subdirectory."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitDefaultTemplateSubdirectory)) "Revit $year is missing its default live-test template."
    Assert-True (@('codedom', 'roslyn') -contains [string]$entry.RevitDynamicCompiler) "Revit $year has an invalid compiler."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitSupportStatus)) "Revit $year is missing support status."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitCertificationStatus)) "Revit $year is missing certification status."
}

$entryByYear = @{}
foreach ($entry in $entries) { $entryByYear[[string]$entry.ReleaseYear] = $entry }
Assert-True ([string]$entryByYear['2025'].RevitUseRevitContext -eq 'true') 'Revit 2025 must remain in the default load context because its manifest schema predates dependency isolation.'
foreach ($isolatedYear in @('2026', '2027')) {
    Assert-True ([string]$entryByYear[$isolatedYear].RevitUseRevitContext -eq 'false') "Revit $isolatedYear must use the supported isolated add-in context."
}

$project = Get-Content -LiteralPath $projectPath -Raw
$adapterPropertiesPath = Join-Path $repositoryRoot 'src\BimBridge.Revit\BimBridge.Revit.Adapter.props'
$adapterProperties = Get-Content -LiteralPath $adapterPropertiesPath -Raw
Assert-True ($adapterProperties.Contains('Autodesk.Versions.props')) 'The Revit adapter must import the version matrix.'
Assert-True ($adapterProperties.Contains('Runtime\NetFramework\RuntimeCodeCompiler.cs')) 'The .NET Framework compiler boundary is missing.'
Assert-True ($adapterProperties.Contains('Runtime\Modern\RuntimeCodeCompiler.cs')) 'The modern compiler boundary is missing.'

$template = Get-Content -LiteralPath $templatePath -Raw
Assert-True ($template.Contains('{{ASSEMBLY_PATH}}')) 'The add-in template is missing the assembly token.'
Assert-True ($template.Contains('{{MANIFEST_SETTINGS}}')) 'The add-in template is missing the manifest-settings token.'

$buildScript = Get-Content -LiteralPath $buildScriptPath -Raw
Assert-True ($buildScript.Contains('Autodesk.Versions.props')) 'The Revit build entry point must consume the version matrix.'
Assert-True ($buildScript.Contains('RevitVersionMatrix.ps1')) 'The Revit build must use the shared runtime resolver.'

$matrixHelper = Get-Content -LiteralPath $matrixHelperPath -Raw
Assert-True ($matrixHelper.Contains('RevitAPI.runtimeconfig.json')) 'Serviced Revit runtimes must resolve from installed API metadata.'
Assert-True ($matrixHelper.Contains('RevitSupportedTargetFrameworks')) 'Resolved runtimes must be bounded by the matrix allow-list.'

$liveScript = Get-Content -LiteralPath $liveScriptPath -Raw
Assert-True ($liveScript.Contains('RevitVersionMatrix.ps1')) 'Live acceptance must use the shared runtime resolver.'
Assert-True ($liveScript.Contains('untrusted_binary')) 'Live acceptance must fail fast for untrusted test add-ins.'
Assert-True (-not $liveScript.Contains('installer\')) 'Live acceptance must remain outside the frozen installer.'
Assert-True ($liveScript.Contains('Sign-RevitLiveTestArtifacts.ps1')) 'Live acceptance must re-sign rebuilt development artifacts.'

$trustScript = Get-Content -LiteralPath $trustScriptPath -Raw
Assert-True ($trustScript.Contains('KeyExportPolicy NonExportable')) 'Development signing keys must be non-exportable.'
Assert-True ($trustScript.Contains('Cert:\CurrentUser\TrustedPublisher')) 'Development trust must be scoped to the current user.'
$signingScript = Get-Content -LiteralPath $signingScriptPath -Raw
Assert-True ($signingScript.Contains('Refusing to sign a file outside the repository')) 'Development signing must be repository-bounded.'
Assert-True ($signingScript.Contains("-ne '.dll'")) 'Development signing must be restricted to DLL artifacts.'

$bootstrapProject = Get-Content -LiteralPath $bootstrapProjectPath -Raw
Assert-True ($bootstrapProject.Contains('Autodesk.Versions.props')) 'The Revit test bootstrap must consume the version matrix.'
$bootstrapSource = Get-Content -LiteralPath $bootstrapSourcePath -Raw
Assert-True ($bootstrapSource.Contains('BIM_BRIDGE_REVIT_LIVE_TEST_REQUEST')) 'The Revit test bootstrap must be inert without a run request.'
Assert-True ($bootstrapSource.Contains('Safety gate refused')) 'The Revit test bootstrap must refuse unexpected documents.'

$liveDriver = Get-Content -LiteralPath $liveDriverPath -Raw
foreach ($requiredTool in @('aec_list_providers', 'aec_list_instances', 'aec_get_document_info', 'aec_get_selection', 'aec_execute_read', 'aec_execute_write')) {
    Assert-True ($liveDriver.Contains($requiredTool)) "Live acceptance is missing MCP route $requiredTool."
}
Assert-True ($liveDriver.Contains('rolledBack')) 'Live acceptance must verify native rollback evidence.'
Assert-True ($liveDriver.Contains('descriptor_cleanup')) 'Live acceptance must verify connector shutdown cleanup.'

$revitExecutor = Get-Content -LiteralPath $revitExecutorPath -Raw
$revitFailurePreprocessor = Get-Content -LiteralPath $revitFailurePreprocessorPath -Raw
Assert-True ($revitFailurePreprocessor.Contains('IFailuresPreprocessor')) 'The shared Revit host must preprocess native failures.'
Assert-True ($revitFailurePreprocessor.Contains('DeleteWarning')) 'Revit warnings must be captured without opening a native modal dialog.'
Assert-True ($revitFailurePreprocessor.Contains('ProceedWithRollBack')) 'Revit errors must fail closed and request rollback.'
Assert-True ($revitExecutor.Contains('SetFailuresPreprocessor')) 'Every connector-owned Revit transaction must install the failure preprocessor.'
Assert-True ($revitExecutor.Contains('SetForcedModalHandling(false)')) 'Connector-owned Revit writes must not wait for a native failure dialog.'
Assert-True ($revitExecutor.Contains('Warnings = failurePreprocessor.Warnings.ToList()')) 'Captured Revit warnings must be returned to the caller.'
Assert-True (-not $revitExecutor.Contains('DialogBoxShowing')) 'The connector must not automate or click Revit dialogs.'

$revitViewCapture = Get-Content -LiteralPath $revitViewCapturePath -Raw
$connectorServer = Get-Content -LiteralPath $connectorServerPath -Raw
$runtimeCapabilities = Get-Content -LiteralPath $runtimeCapabilitiesPath -Raw
$runtimeService = Get-Content -LiteralPath $runtimeServicePath -Raw
Assert-True ($revitViewCapture.Contains('ImageExportOptions')) 'Revit view capture must use the native image exporter.'
Assert-True ($revitViewCapture.Contains('SpecialFolder.LocalApplicationData')) 'Capture output must remain in bounded current-user state.'
Assert-True (-not $revitViewCapture.Contains('new Transaction(')) 'Read-only view capture must not modify the Revit model.'
Assert-True ($revitExecutor.Contains('"view.capture"')) 'The shared Revit connector must advertise view.capture.'
Assert-True ($connectorServer.Contains('operation == "view.capture"')) 'The frozen execute route must carry the structured capture operation.'
Assert-True ($runtimeCapabilities.Contains('"revit.view.capture"')) 'The Runtime capability registry must own the typed capture definition.'
Assert-True ($runtimeService.Contains('REVIT_HOST_PROVIDER_ID')) 'The existing provider MCP projection must expose host capture discovery.'

$legacySourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src') -Directory |
    Where-Object { $_.Name -match '^BimBridge\.Revit\d{4}$' } |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.cs' -Recurse } |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' })
Assert-True ($legacySourceFiles.Count -eq 0) 'Year-specific Revit business source files are not allowed.'

[ordered]@{
    status = 'passed'
    releases = $years
    sharedProject = $projectPath
} | ConvertTo-Json -Depth 3
