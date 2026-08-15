[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Start-BimBridgeWorkBuddyMcp.ps1'))
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "WorkBuddy BIM Bridge launcher is missing: $launcher"
}

[ordered]@{
    mcpServers = [ordered]@{
        'bim-bridge' = [ordered]@{
            type = 'stdio'
            command = 'powershell.exe'
            args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $launcher)
            description = 'BIM Bridge local Revit and AutoCAD tools'
        }
    }
} | ConvertTo-Json -Depth 8
