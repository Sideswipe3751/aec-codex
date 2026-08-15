[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$baselinePath = Join-Path $repositoryRoot 'protocol\v1\baseline.json'
$serverPath = Join-Path $repositoryRoot 'plugins\aec-codex\mcp-server\aec_mcp_server.py'
$connectorServerPath = Join-Path $repositoryRoot 'src\BimBridge.Host\ConnectorServer.cs'
$contractsPath = Join-Path $repositoryRoot 'src\BimBridge.Host\ConnectorContracts.cs'

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) {
        throw "$Message Missing '$Expected'."
    }
}

$baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
$python = Get-Command python -ErrorAction Stop
$probe = @'
import hashlib, importlib.util, json, pathlib, sys
path = pathlib.Path(sys.argv[1]).resolve()
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location("aec_mcp_server_v1_contract", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
canonical = json.dumps(module.TOOLS, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
print(json.dumps({
    "serverVersion": module.SERVER_VERSION,
    "supportedProtocolVersions": list(module.SUPPORTED_MCP_VERSIONS),
    "toolNames": [tool["name"] for tool in module.TOOLS],
    "toolSurfaceCanonicalSha256": hashlib.sha256(canonical).hexdigest(),
}))
'@
$actual = $probe | & $python.Source - $serverPath | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Unable to probe the current Codex MCP v1 surface.' }

Assert-Equal $actual.serverVersion $baseline.codexMcp.serverVersion 'Codex MCP server version changed without a v1 baseline update.'
Assert-Equal $actual.toolSurfaceCanonicalSha256 $baseline.codexMcp.toolSurfaceCanonicalSha256 'Codex MCP tool schemas or annotations changed without a v1 compatibility decision.'
Assert-Equal (($actual.toolNames | ConvertTo-Json -Compress)) (($baseline.codexMcp.toolNames | ConvertTo-Json -Compress)) 'Codex MCP tool order or names changed.'
Assert-Equal (($actual.supportedProtocolVersions | ConvertTo-Json -Compress)) (($baseline.codexMcp.supportedProtocolVersions | ConvertTo-Json -Compress)) 'Supported MCP versions changed.'

$connectorServer = Get-Content -LiteralPath $connectorServerPath -Raw
$contracts = Get-Content -LiteralPath $contractsPath -Raw
Assert-Contains $connectorServer 'request.Headers["Authorization"]' 'Connector v1 bearer authorization changed.'
Assert-Contains $connectorServer 'const string prefix = "Bearer ";' 'Connector v1 bearer authorization prefix changed.'

foreach ($route in $baseline.connectorHttp.routes) {
    $path = [string]$route.path
    if ($path.Contains('{requestId}')) {
        Assert-Contains $connectorServer 'path.StartsWith("/v1/requests/"' "Connector route $($route.method) $path changed."
        if ($path.EndsWith('/cancel')) {
            Assert-Contains $connectorServer 'relative.EndsWith("/cancel"' "Connector cancel route $path changed."
        }
    } else {
        Assert-Contains $connectorServer "path == `"$path`"" "Connector route $($route.method) $path changed."
    }
}

foreach ($status in $baseline.connectorHttp.requestStatuses) {
    Assert-Contains $contracts "return `"$status`";" "Connector request status $status changed."
}
foreach ($mode in $baseline.connectorHttp.executeModes) {
    Assert-Contains $connectorServer "mode != `"$mode`"" "Connector execute mode $mode changed."
}

[ordered]@{
    status = 'passed'
    baseline = $baselinePath
    mcpServerVersion = $actual.serverVersion
    toolCount = @($actual.toolNames).Count
    connectorRouteCount = @($baseline.connectorHttp.routes).Count
    requestStatusCount = @($baseline.connectorHttp.requestStatuses).Count
} | ConvertTo-Json
