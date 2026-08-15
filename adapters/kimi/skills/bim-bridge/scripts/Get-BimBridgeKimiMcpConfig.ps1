[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Start-BimBridgeKimiMcp.ps1'))
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Kimi Code BIM Bridge launcher is missing: $launcher"
}

[ordered]@{
    mcpServers = [ordered]@{
        'bim-bridge' = [ordered]@{
            command = 'powershell.exe'
            args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $launcher)
            startupTimeoutMs = 30000
        }
    }
} | ConvertTo-Json -Depth 8
