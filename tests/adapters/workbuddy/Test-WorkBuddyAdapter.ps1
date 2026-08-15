[CmdletBinding()]
param(
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDirectory))
}

$adapterRoot = Join-Path $SourceRoot 'adapters\workbuddy'
$skillRoot = Join-Path $adapterRoot 'skills\bim-bridge'
$marketplacePath = Join-Path $SourceRoot '.codebuddy-plugin\marketplace.json'
$pluginManifestPath = Join-Path $adapterRoot '.codebuddy-plugin\plugin.json'
$pluginMcpPath = Join-Path $adapterRoot '.mcp.json'
$skillPath = Join-Path $skillRoot 'SKILL.md'
$drawingQualityPath = Join-Path $skillRoot 'references\drawing-quality.md'
$modelReconstructionPath = Join-Path $skillRoot 'references\model-reconstruction.md'
$statusScript = Join-Path $skillRoot 'scripts\Get-BimBridgeWorkBuddyStatus.ps1'
$configScript = Join-Path $skillRoot 'scripts\Get-BimBridgeWorkBuddyMcpConfig.ps1'
$launcherScript = Join-Path $skillRoot 'scripts\Start-BimBridgeWorkBuddyMcp.ps1'
$scopePath = Join-Path $SourceRoot 'CODEBUDDY.md'

foreach ($path in @(
    $marketplacePath,
    $pluginManifestPath,
    $pluginMcpPath,
    $skillPath,
    $drawingQualityPath,
    $modelReconstructionPath,
    $statusScript,
    $configScript,
    $launcherScript,
    $scopePath
)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing WorkBuddy adapter file: $path" }
}

foreach ($script in @($statusScript, $configScript, $launcherScript)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "PowerShell parse failure in $script`: $($errors[0].Message)" }
}
Write-Host 'PASS WorkBuddy adapter scripts parse'

$scope = Get-Content -LiteralPath $scopePath -Raw -Encoding UTF8
foreach ($requiredScope in @('adapters/workbuddy/**', 'tests/adapters/workbuddy/**', 'runtime/**', 'protocol/v1/baseline.json')) {
    if (-not $scope.Contains($requiredScope)) { throw "CODEBUDDY.md is missing scope boundary: $requiredScope" }
}
Write-Host 'PASS CODEBUDDY.md declares writable and protected scope'

$marketplace = Get-Content -LiteralPath $marketplacePath -Raw -Encoding UTF8 | ConvertFrom-Json
$pluginManifest = Get-Content -LiteralPath $pluginManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pluginMcp = Get-Content -LiteralPath $pluginMcpPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$marketplace.name -ne 'bim-bridge') { throw 'WorkBuddy Marketplace name must remain bim-bridge.' }
$marketplaceEntries = @($marketplace.plugins | Where-Object { $_.name -eq 'bim-bridge' })
if ($marketplaceEntries.Count -ne 1 -or [string]$marketplaceEntries[0].source -ne './adapters/workbuddy') {
    throw 'WorkBuddy Marketplace must expose exactly one repository-relative bim-bridge Plugin.'
}
if ([string]$pluginManifest.name -ne 'bim-bridge' -or [string]$pluginManifest.version -ne [string]$marketplaceEntries[0].version) {
    throw 'WorkBuddy Plugin identity and version must match its Marketplace entry.'
}
if (-not (@($pluginManifest.skills) -contains './skills/bim-bridge') -or [string]$pluginManifest.mcpServers -ne './.mcp.json') {
    throw 'WorkBuddy Plugin must bundle the BIM Bridge Skill and MCP declaration.'
}
$pluginServer = $pluginMcp.mcpServers.'bim-bridge'
$pluginLauncher = [string]@($pluginServer.args)[-1]
$expectedPluginLauncher = '${CODEBUDDY_PLUGIN_ROOT}/skills/bim-bridge/scripts/Start-BimBridgeWorkBuddyMcp.ps1'
if ([string]$pluginServer.type -ne 'stdio' -or [string]$pluginServer.command -ne 'powershell.exe' -or $pluginLauncher -ne $expectedPluginLauncher) {
    throw 'WorkBuddy Plugin MCP must use the relocatable verified launcher wrapper.'
}
$pluginMcpRaw = Get-Content -LiteralPath $pluginMcpPath -Raw -Encoding UTF8
if ($pluginMcpRaw -match '[A-Za-z]:\\Users\\' -or $pluginMcpRaw.Contains([Environment]::UserName)) {
    throw 'WorkBuddy Plugin MCP must not contain a user-specific absolute path.'
}
$skill = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
foreach ($requiredSkillText in @('references/drawing-quality.md', 'references/model-reconstruction.md', '${CODEBUDDY_PLUGIN_ROOT}')) {
    if (-not $skill.Contains($requiredSkillText)) { throw "WorkBuddy Skill is missing required guidance: $requiredSkillText" }
}
$modelReconstruction = Get-Content -LiteralPath $modelReconstructionPath -Raw -Encoding UTF8
foreach ($requiredGate in @('Core-form rule', 'Completion gate', 'fast mode', 'representative positions')) {
    if (-not $modelReconstruction.Contains($requiredGate)) { throw "WorkBuddy reconstruction guidance is missing quality gate: $requiredGate" }
}
Write-Host 'PASS WorkBuddy Marketplace Plugin bundles relocatable Skill and MCP assets'

$config = (& $configScript) | ConvertFrom-Json
$server = $config.mcpServers.'bim-bridge'
if ([string]$server.type -ne 'stdio' -or [string]$server.command -ne 'powershell.exe') {
    throw 'Generated WorkBuddy MCP configuration is not a PowerShell stdio server.'
}
$generatedLauncher = [string]@($server.args)[-1]
if ([IO.Path]::GetFullPath($generatedLauncher) -ne [IO.Path]::GetFullPath($launcherScript)) {
    throw 'Generated WorkBuddy MCP configuration does not target the bundled launcher wrapper.'
}
Write-Host 'PASS WorkBuddy MCP configuration is absolute and deterministic'

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-workbuddy-test-' + [Guid]::NewGuid().ToString('N'))
$hostRoot = Join-Path $temporaryRoot 'host\test'
$mcpRoot = Join-Path $hostRoot 'mcp-server'
$pythonRoot = Join-Path $hostRoot 'python'
New-Item -ItemType Directory -Force -Path $mcpRoot, $pythonRoot | Out-Null
try {
    $fakeLauncher = Join-Path $hostRoot 'Start-BimBridgeMcp.ps1'
    $fakePython = Join-Path $pythonRoot 'python.exe'
    $fakeServer = Join-Path $mcpRoot 'aec_mcp_server.py'
    Set-Content -LiteralPath $fakeLauncher -Value "Write-Output 'fake-workbuddy-mcp'" -Encoding UTF8
    Set-Content -LiteralPath $fakePython -Value 'test' -Encoding UTF8
    Set-Content -LiteralPath $fakeServer -Value 'test' -Encoding UTF8
    $files = @($fakeLauncher, $fakePython, $fakeServer) | ForEach-Object {
        [ordered]@{ path=[IO.Path]::GetFullPath($_); sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    [ordered]@{
        schemaVersion = 4
        version = 'test'
        launcher = [IO.Path]::GetFullPath($fakeLauncher)
        python = [IO.Path]::GetFullPath($fakePython)
        localMcpServer = [IO.Path]::GetFullPath($fakeServer)
        files = $files
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8

    $status = (& $statusScript -StateRoot $temporaryRoot -WorkBuddyVersionOverride '5.1.0') | ConvertFrom-Json
    if ([string]$status.status -ne 'healthy' -or [string]$status.adapter -ne 'workbuddy') {
        throw "Healthy fixture returned unexpected status: $($status.status)"
    }
    Write-Host 'PASS WorkBuddy read-only status accepts a healthy neutral Host'

    Set-Content -LiteralPath $fakeServer -Value 'changed' -Encoding UTF8
    $changed = (& $statusScript -StateRoot $temporaryRoot -WorkBuddyVersionOverride '5.1.0') | ConvertFrom-Json
    if ([string]$changed.status -ne 'needs_repair' -or @($changed.host.changedFiles).Count -ne 1) {
        throw 'Changed MCP server was not reported as a Host repair condition.'
    }
    Write-Host 'PASS WorkBuddy read-only status detects changed Host files'

    $invalidState = Get-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Raw | ConvertFrom-Json
    $invalidState.PSObject.Properties.Remove('files')
    $invalidState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8
    $invalid = (& $statusScript -StateRoot $temporaryRoot -WorkBuddyVersionOverride '5.1.0') | ConvertFrom-Json
    if ([string]$invalid.status -ne 'needs_repair' -or [string]$invalid.host.stateError -notmatch "missing 'files'") {
        throw 'Missing Host file manifest was not reported as a repair condition.'
    }
    Write-Host 'PASS WorkBuddy read-only status fails closed on incomplete Host state'

    Set-Content -LiteralPath $fakeServer -Value 'test' -Encoding UTF8
    [ordered]@{
        schemaVersion = 4
        version = 'test'
        launcher = [IO.Path]::GetFullPath($fakeLauncher)
        python = [IO.Path]::GetFullPath($fakePython)
        localMcpServer = [IO.Path]::GetFullPath($fakeServer)
        files = $files
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install-state.json') -Encoding UTF8
    $output = & $launcherScript -StateRoot $temporaryRoot
    if ([string]$output -ne 'fake-workbuddy-mcp') { throw 'Verified WorkBuddy launcher did not delegate to the neutral Host launcher.' }
    Write-Host 'PASS WorkBuddy launcher verifies and delegates to the neutral Host'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe test cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
