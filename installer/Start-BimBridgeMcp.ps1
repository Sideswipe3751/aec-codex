[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-McpError([string]$Message) {
    [Console]::Error.WriteLine('BIM Bridge: ' + $Message)
}

try {
    $stateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'BIM Bridge'
    $statePath = Join-Path $stateRoot 'install-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "BIM Bridge host state is missing: $statePath"
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $serverPath = [string]$state.localMcpServer
    $pythonPath = [string]$state.python
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) { throw "MCP server is missing: $serverPath" }
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) { throw "Python runtime is missing: $pythonPath" }

    $env:BIM_BRIDGE_RUNTIME_ROOT = Join-Path (Split-Path -Parent $serverPath) 'runtime'
    & $pythonPath $serverPath
    exit $LASTEXITCODE
} catch {
    Write-McpError $_.Exception.Message
    exit 1
}
