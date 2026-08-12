[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-McpError([string]$Message) {
    [Console]::Error.WriteLine('AEC Codex: ' + $Message)
}

try {
    $pluginRoot = Split-Path -Parent $PSScriptRoot
    $stateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'AEC Codex'
    $statePath = Join-Path $stateRoot 'install-state.json'
    $serverPath = $null

    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $serverProperty = $state.PSObject.Properties['localMcpServer']
            if ($serverProperty -and $serverProperty.Value -and (Test-Path -LiteralPath $serverProperty.Value -PathType Leaf)) {
                $serverPath = $serverProperty.Value
            }
        } catch {
            Write-McpError ('ignoring unreadable install state: ' + $_.Exception.Message)
        }
    }
    if (-not $serverPath) {
        $serverPath = Join-Path $pluginRoot 'mcp-server\aec_mcp_server.py'
    }
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
        throw "MCP server is missing: $serverPath"
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        throw 'Python 3.11 or newer is required. Start a task with the AEC Codex setup prompt to install or diagnose the local host.'
    }
    & $python.Source $serverPath
    exit $LASTEXITCODE
} catch {
    Write-McpError $_.Exception.Message
    exit 1
}
