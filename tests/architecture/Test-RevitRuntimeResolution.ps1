$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'eng\RevitVersionMatrix.ps1')

function Assert-Equal([object]$Expected, [object]$Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) { throw "$Message Expected '$Expected', got '$Actual'." }
}

$testRoot = Join-Path $env:TEMP ('bim-bridge-runtime-resolution-' + [Guid]::NewGuid().ToString('N'))
$programFiles = Join-Path $testRoot 'ProgramFiles'
$programData = Join-Path $testRoot 'ProgramData'
try {
    $release = [pscustomobject]@{
        Include = '2999'
        AssemblyName = 'BimBridge.Revit2999'
        ManifestName = 'BimBridge.Revit2999.addin'
        TargetFramework = 'net8.0-windows'
        SupportedTargetFrameworks = 'net8.0-windows;net10.0-windows'
        CertifiedTargetFrameworks = 'net10.0-windows'
        RuntimeFamily = 'modern'
        RuntimeResolution = 'installed-api-runtime'
        DynamicCompiler = 'roslyn'
        UseRevitContext = 'false'
        ProviderAvailable = 'false'
        SupportStatus = 'experimental'
        CertificationStatus = 'certified'
        InstallSubdirectory = 'Autodesk\Revit Test'
        DefaultTemplateSubdirectory = 'Autodesk\RVT Test\Templates\Default.rte'
    }
    $install = Join-Path $programFiles $release.InstallSubdirectory
    New-Item -ItemType Directory -Path $install -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $programData $release.DefaultTemplateSubdirectory)) -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $install 'RevitAPI.dll') -Force | Out-Null

    foreach ($case in @(
        @{ tfm='net8.0'; expected='net8.0-windows' },
        @{ tfm='net10.0'; expected='net10.0-windows' }
    )) {
        $payload = @{ runtimeOptions = @{ tfm = $case.tfm } } | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText((Join-Path $install 'RevitAPI.runtimeconfig.json'), $payload, [Text.UTF8Encoding]::new($false))
        $resolved = Resolve-RevitMatrixEntry $release $programFiles $programData
        Assert-Equal $case.expected $resolved.TargetFramework "Installed runtime $($case.tfm) resolved incorrectly."
        Assert-Equal $case.tfm $resolved.DetectedRuntime 'Detected runtime evidence was not preserved.'
    }

    [IO.File]::WriteAllText(
        (Join-Path $install 'RevitAPI.runtimeconfig.json'),
        (@{ runtimeOptions = @{ tfm = 'net8.0' } } | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false))
    $uncertifiedRejected = $false
    try { Resolve-RevitMatrixEntry $release $programFiles $programData -RequireCertified | Out-Null } catch {
        $uncertifiedRejected = $_.Exception.Message -like '*not certified*net10.0-windows*'
    }
    if (-not $uncertifiedRejected) { throw 'An installed but uncertified runtime variant must fail closed.' }

    [IO.File]::WriteAllText(
        (Join-Path $install 'RevitAPI.runtimeconfig.json'),
        (@{ runtimeOptions = @{ tfm = 'net10.0' } } | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false))
    $certified = Resolve-RevitMatrixEntry $release $programFiles $programData -RequireCertified
    Assert-Equal 'net10.0-windows' $certified.TargetFramework 'The certified runtime variant was rejected.'

    [IO.File]::WriteAllText(
        (Join-Path $install 'RevitAPI.runtimeconfig.json'),
        (@{ runtimeOptions = @{ tfm = 'net12.0' } } | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false))
    $rejected = $false
    try { Resolve-RevitMatrixEntry $release $programFiles $programData | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'An undeclared future runtime must fail closed.' }

    [ordered]@{ status='passed'; resolved=@('net8.0-windows','net10.0-windows'); uncertifiedRejected='net8.0-windows'; rejected='net12.0' } | ConvertTo-Json
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith('bim-bridge-runtime-resolution-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
