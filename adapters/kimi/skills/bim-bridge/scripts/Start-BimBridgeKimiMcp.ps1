[CmdletBinding()]
param(
    [string]$StateRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-McpError([string]$Message) {
    [Console]::Error.WriteLine('BIM Bridge Kimi adapter: ' + $Message)
}

function Get-RecordedHash($State, [string]$Path) {
    foreach ($file in @($State.files)) {
        if ($file.path -and [IO.Path]::GetFullPath([string]$file.path) -eq $Path) {
            return [string]$file.sha256
        }
    }
    return $null
}

try {
    if (-not $StateRoot) {
        $StateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'BIM Bridge'
    }
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)
    $statePath = Join-Path $StateRoot 'install-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "BIM Bridge Host state is missing: $statePath"
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.schemaVersion -ne 4) { throw 'Unsupported BIM Bridge install-state schema.' }
    $launcher = [IO.Path]::GetFullPath([string]$state.launcher)
    $hostRoot = [IO.Path]::GetFullPath((Join-Path $StateRoot 'host'))
    $hostPrefix = $hostRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $launcher.StartsWith($hostPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recorded Host launcher is outside the BIM Bridge Host root: $launcher"
    }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Recorded Host launcher is missing: $launcher"
    }

    $expectedHash = Get-RecordedHash $state $launcher
    if ([string]::IsNullOrWhiteSpace($expectedHash) -or $expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Recorded Host launcher does not have a valid installation hash.'
    }
    $actualHash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
        throw "Recorded Host launcher hash mismatch: $launcher"
    }

    $env:BIM_BRIDGE_AGENT_ADAPTER = 'kimi'
    & $launcher
    $processExitCode = 0
    $lastExitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($lastExitCodeVariable) { $processExitCode = [int]$lastExitCodeVariable.Value }
    exit $processExitCode
} catch {
    Write-McpError $_.Exception.Message
    exit 1
}
