[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ZipPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ZipPath = [IO.Path]::GetFullPath($ZipPath)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-mixed-runtime-' + [Guid]::NewGuid().ToString('N'))
$originalProgramFiles = $env:ProgramFiles
try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $testRoot
    $fakeProgramFiles = Join-Path $testRoot 'ProgramFiles'
    foreach ($case in @(
        @{ version='2026'; tfm='net8.0' },
        @{ version='2027'; tfm='net10.0' }
    )) {
        $install = Join-Path $fakeProgramFiles ('Autodesk\Revit ' + $case.version)
        New-Item -ItemType Directory -Force -Path $install | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $install 'Revit.exe') | Out-Null
        $runtime = [ordered]@{ runtimeOptions=[ordered]@{ tfm=$case.tfm } } | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText(
            (Join-Path $install 'RevitAPI.runtimeconfig.json'),
            $runtime,
            [Text.UTF8Encoding]::new($false))
    }

    $env:ProgramFiles = $fakeProgramFiles
    $sourceRoot = Join-Path $testRoot 'bim-bridge'
    $result = (& (Join-Path $sourceRoot 'installer\Install-BimBridge.ps1') `
        -SourceRoot $sourceRoot -SkipBuild -ValidateOnly) | ConvertFrom-Json

    if (@($result.revit) -notcontains '2027') { throw 'Compatible Revit 2027 was not validated.' }
    if (@($result.revit) -contains '2026') { throw 'Incompatible Revit 2026 was not skipped.' }
    $skip = @($result.skippedProducts | Where-Object { $_.product -eq 'revit' -and $_.version -eq '2026' })
    if ($skip.Count -ne 1 -or [string]$skip[0].reason -notlike '*net8.0-windows*not certified*net10.0-windows*') {
        throw 'Revit 2026 skip evidence is missing or incomplete.'
    }

    [ordered]@{
        status='passed'
        compatibleRevit=@($result.revit)
        skippedProducts=@($result.skippedProducts)
    } | ConvertTo-Json -Depth 8
} finally {
    $env:ProgramFiles = $originalProgramFiles
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $resolved).StartsWith('bim-bridge-mixed-runtime-', [StringComparison]::Ordinal)) {
            throw "Unsafe mixed-runtime test cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
