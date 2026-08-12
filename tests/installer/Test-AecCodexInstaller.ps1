[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$statusScript = Join-Path $repoRoot 'plugins\aec-codex\scripts\Get-AecCodexHostStatus.ps1'
$hostInstaller = Join-Path $repoRoot 'plugins\aec-codex\scripts\Install-AecCodexHost.ps1'
$mainInstaller = Join-Path $repoRoot 'installer\Install-AecCodex.ps1'
$bootstrap = Join-Path $repoRoot 'installer\bootstrap.ps1'
$releaseBuilder = Join-Path $repoRoot 'installer\New-AecCodexRelease.ps1'
$submissionBuilder = Join-Path $repoRoot 'installer\New-AecCodexSubmission.ps1'
$pluginManifestPath = Join-Path $repoRoot 'plugins\aec-codex\.codex-plugin\plugin.json'
$releaseManifestPath = Join-Path $repoRoot 'plugins\aec-codex\release-manifest.json'
$marketplacePath = Join-Path $repoRoot '.agents\plugins\marketplace.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-installer-tests-' + [Guid]::NewGuid().ToString('N'))
$script:Failures = New-Object System.Collections.ArrayList

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Test([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "PASS $Name"
    } catch {
        [void]$script:Failures.Add("$Name`: $($_.Exception.Message)")
        Write-Host "FAIL $Name`: $($_.Exception.Message)"
    }
}

function Invoke-Status([string]$CaseRoot, [string]$CodexStart) {
    $stateRoot = Join-Path $CaseRoot 'local\AEC Codex'
    $roaming = Join-Path $CaseRoot 'roaming'
    $local = Join-Path $CaseRoot 'local'
    $programs = Join-Path $CaseRoot 'programs'
    New-Item -ItemType Directory -Force -Path $stateRoot,$roaming,$local,$programs | Out-Null
    $arguments = @{
        StateRoot=$stateRoot; RoamingRoot=$roaming; LocalRoot=$local
        ProgramFilesRoot=$programs; ProgramFilesX86Root=$programs
    }
    if ($CodexStart) { $arguments.CodexStartedAtUtc = $CodexStart }
    (& $statusScript @arguments) | ConvertFrom-Json
}

New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    Invoke-Test 'PowerShell scripts parse on Windows PowerShell' {
        foreach ($path in @($statusScript, $hostInstaller, $mainInstaller, $bootstrap, $releaseBuilder, $submissionBuilder, (Join-Path $repoRoot 'installer\Install-AecProviders.ps1'))) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
            Assert ($errors.Count -eq 0) "$path has parser errors."
        }
    }

    Invoke-Test 'plugin, release, MCP, and marketplace versions agree' {
        $plugin = Get-Content -LiteralPath $pluginManifestPath -Raw | ConvertFrom-Json
        $release = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
        $marketplace = Get-Content -LiteralPath $marketplacePath -Raw | ConvertFrom-Json
        Assert ($plugin.version -eq '1.1.0-rc.3') 'Plugin version is not rc.3.'
        Assert ($release.version -eq $plugin.version) 'Release manifest version differs from plugin version.'
        if ($release.published) { Assert ($release.sha256 -match '^[a-f0-9]{64}$') 'Published release manifest has no finalized SHA-256.' }
        Assert ($release.privatePythonVersion -eq '3.12.10') 'Private Python runtime version is not pinned.'
        Assert ($plugin.interface.defaultPrompt.Count -le 3) 'Plugin has more than three starter prompts.'
        Assert ($marketplace.plugins.Count -eq 1) 'Repository marketplace should contain one plugin.'
        Assert ($marketplace.plugins[0].source.path -eq './plugins/aec-codex') 'Marketplace source path is invalid.'
        $serverText = Get-Content -LiteralPath (Join-Path $repoRoot 'plugins\aec-codex\mcp-server\aec_mcp_server.py') -Raw
        Assert ($serverText.Contains('SERVER_VERSION = "1.1.0-rc.3"')) 'MCP host version differs from plugin version.'
        $versionedFiles = @(
            'plugins\aec-codex\mcp-server\provider_gateway.py',
            'src\Aec.Codex.Bridge\ConnectorContracts.cs',
            'src\Aec.Codex.AutoCAD2024\AutoCADConnectorExecutor.cs',
            'src\Aec.Codex.Revit2024\RevitConnectorExecutor.cs'
        )
        foreach ($relativePath in $versionedFiles) {
            $text = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw
            Assert ($text.Contains('1.1.0-rc.3')) "$relativePath does not report rc.3."
            Assert (-not $text.Contains('1.1.0-rc.2')) "$relativePath still reports rc.2."
        }
    }

    Invoke-Test 'fresh compatible PC reports not_installed' {
        $result = Invoke-Status (Join-Path $temporaryRoot 'fresh') $null
        Assert ($result.status -eq 'not_installed') "Expected not_installed, received $($result.status)."
        Assert ($result.recommendedAction -eq 'install') 'Fresh status did not recommend install.'
    }

    Invoke-Test 'partial install reports needs_repair' {
        $caseRoot = Join-Path $temporaryRoot 'partial'
        $bundle = Join-Path $caseRoot 'roaming\Autodesk\ApplicationPlugins\AEC Codex.bundle'
        New-Item -ItemType Directory -Force -Path $bundle | Out-Null
        Set-Content -LiteralPath (Join-Path $bundle 'PackageContents.xml') -Value '<ApplicationPackage />' -Encoding UTF8
        $result = Invoke-Status $caseRoot $null
        Assert ($result.status -eq 'needs_repair') "Expected needs_repair, received $($result.status)."
    }

    Invoke-Test 'healthy state verifies installed hashes' {
        $caseRoot = Join-Path $temporaryRoot 'healthy'
        $stateRoot = Join-Path $caseRoot 'local\AEC Codex'
        $installedFile = Join-Path $stateRoot 'host\1.1.0-rc.3\mcp-server\aec_mcp_server.py'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installedFile) | Out-Null
        Set-Content -LiteralPath $installedFile -Value 'healthy' -Encoding UTF8
        $hash = (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash.ToLowerInvariant()
        [ordered]@{
            schemaVersion=3; version='1.1.0-rc.3'; installedAtUtc='2026-08-11T20:00:00Z'
            installMode='HostOnly'; restartRequired=$true
            files=@([ordered]@{ path=$installedFile; sha256=$hash })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stateRoot 'install-state.json') -Encoding UTF8
        $result = Invoke-Status $caseRoot '2026-08-11T20:01:00Z'
        Assert ($result.status -eq 'healthy') "Expected healthy, received $($result.status)."

        Set-Content -LiteralPath $installedFile -Value 'changed' -Encoding UTF8
        $changed = Invoke-Status $caseRoot '2026-08-11T20:01:00Z'
        Assert ($changed.status -eq 'needs_repair') 'Changed installed file did not require repair.'
    }

    Invoke-Test 'old Codex process reports restart_required' {
        $caseRoot = Join-Path $temporaryRoot 'restart'
        $stateRoot = Join-Path $caseRoot 'local\AEC Codex'
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
        [ordered]@{
            schemaVersion=3; version='1.1.0-rc.3'; installedAtUtc='2026-08-11T20:00:00Z'
            installMode='HostOnly'; restartRequired=$true; files=@()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stateRoot 'install-state.json') -Encoding UTF8
        $result = Invoke-Status $caseRoot '2026-08-11T19:59:00Z'
        Assert ($result.status -eq 'restart_required') "Expected restart_required, received $($result.status)."
    }

    Invoke-Test 'host installer refuses mutation without approval' {
        $message = $null
        try { & $hostInstaller } catch { $message = $_.Exception.Message }
        Assert ($message -like '*explicit user approval*') 'Missing approval was not rejected before installation.'
    }

    Invoke-Test 'unpublished release is blocked clearly' {
        $unpublishedManifest = Join-Path $temporaryRoot 'unpublished-manifest.json'
        $unpublished = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
        $unpublished.published = $false
        $unpublished | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $unpublishedManifest -Encoding UTF8
        $message = $null
        try { & $hostInstaller -UserApproved -ManifestPath $unpublishedManifest } catch { $message = $_.Exception.Message }
        Assert ($message -like '*has not been published*') 'Unpublished manifest was not blocked.'
    }

    Invoke-Test 'checksum mismatch aborts before extraction' {
        $fakeZip = Join-Path $temporaryRoot 'not-a-release.zip'
        Set-Content -LiteralPath $fakeZip -Value 'not a release' -Encoding UTF8
        $message = $null
        try { & $bootstrap -UserApproved -ReleaseZipUri $fakeZip -Sha256 ('0' * 64) } catch { $message = $_.Exception.Message }
        Assert ($message -like '*checksum mismatch*') 'Checksum mismatch was not reported.'
    }

    Invoke-Test 'HostOnly contract preserves marketplace plugin' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($installerText.Contains("[ValidateSet('HostOnly', 'Development')]")) 'InstallMode contract is missing.'
        Assert ($installerText.Contains("if (`$InstallMode -eq 'Development')")) 'Plugin registration is not gated by Development mode.'
        $hostScriptText = Get-Content -LiteralPath $hostInstaller -Raw
        Assert ($hostScriptText.Contains('-InstallMode HostOnly')) 'Host bootstrap does not uninstall in HostOnly mode.'
        Assert ($hostScriptText.Contains("InstallMode = 'HostOnly'")) 'Host bootstrap does not install in HostOnly mode.'
        Assert ($installerText.Contains("`$codexMcpName = 'aec-codex-local'")) 'HostOnly external MCP name is missing.'
        Assert ($installerText.Contains('Register-CodexMcp')) 'HostOnly does not register the external MCP.'
        Assert (-not $installerText.Contains('Python 3.11 or newer is required by the local MCP host.')) 'HostOnly still requires system Python.'
    }

    Invoke-Test 'release and submission builders enforce public contracts' {
        $releaseText = Get-Content -LiteralPath $releaseBuilder -Raw
        $submissionText = Get-Content -LiteralPath $submissionBuilder -Raw
        Assert ($releaseText.Contains("'runtime\python\python.exe'")) 'Release does not require the private Python runtime.'
        Assert ($releaseText.Contains("method='initialize'")) 'Release does not handshake with the staged MCP.'
        Assert ($submissionText.Contains("'.mcp.json', 'marketplace.json'")) 'Submission bundle does not block local MCP or marketplace files.'
        Assert ($submissionText.Contains("'^\.(exe|dll|whl|pfx|p12|pem|key)$'")) 'Submission bundle does not block native binaries and key files.'
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe installer-test cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures.Count -gt 0) { throw ($script:Failures -join [Environment]::NewLine) }
