[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pluginRoot = Join-Path $repoRoot 'plugins\bim-bridge'
$statusScript = Join-Path $pluginRoot 'scripts\Get-BimBridgeHostStatus.ps1'
$hostInstaller = Join-Path $pluginRoot 'scripts\Install-BimBridgeHost.ps1'
$releaseVerifier = Join-Path $pluginRoot 'scripts\Test-BimBridgeReleaseManifest.ps1'
$mainInstaller = Join-Path $repoRoot 'installer\Install-BimBridge.ps1'
$launcher = Join-Path $repoRoot 'installer\Start-BimBridgeMcp.ps1'
$matrixPath = Join-Path $repoRoot 'eng\Autodesk.Versions.props'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bim-bridge-installer-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Test([string]$Name, [scriptblock]$Body) {
    & $Body
    Write-Output "PASS $Name"
}

function Invoke-Status([string]$CaseRoot, [string]$CodexStart, [bool]$McpRegistered = $false) {
    $stateRoot = Join-Path $CaseRoot 'local\BIM Bridge'
    $roaming = Join-Path $CaseRoot 'roaming'
    $local = Join-Path $CaseRoot 'local'
    $programFiles = Join-Path $CaseRoot 'program-files'
    $programFilesX86 = Join-Path $CaseRoot 'program-files-x86'
    New-Item -ItemType Directory -Force -Path $roaming,$local,$programFiles,$programFilesX86 | Out-Null
    $arguments = @{
        StateRoot = $stateRoot
        RoamingRoot = $roaming
        LocalRoot = $local
        ProgramFilesRoot = $programFiles
        ProgramFilesX86Root = $programFilesX86
        CodexMcpRegisteredOverride = $McpRegistered
    }
    if ($CodexStart) { $arguments.CodexStartedAtUtc = $CodexStart }
    (& $statusScript @arguments) | ConvertFrom-Json
}

try {
    Invoke-Test 'new installer scripts parse on Windows PowerShell' {
        foreach ($script in @($statusScript,$hostInstaller,$releaseVerifier,$mainInstaller,$launcher)) {
            [void][scriptblock]::Create((Get-Content -LiteralPath $script -Raw))
        }
    }

    Invoke-Test 'plugin and release versions agree' {
        $plugin = Get-Content -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
        $release = Get-Content -LiteralPath (Join-Path $pluginRoot 'release-manifest.json') -Raw | ConvertFrom-Json
        Assert ($plugin.name -eq 'bim-bridge') 'Plugin ID is not bim-bridge.'
        Assert (([string]$plugin.version -replace '\+.*$','') -eq [string]$release.version) 'Plugin and release versions differ.'
        Assert (-not $plugin.PSObject.Properties['mcpServers']) 'The lightweight bootstrap plugin must not own an MCP server.'
    }

    Invoke-Test 'release manifest has a valid detached signature and rejects tampering' {
        . $releaseVerifier
        $manifestPath = Join-Path $pluginRoot 'release-manifest.json'
        $signaturePath = $manifestPath + '.sig'
        $verified = Read-VerifiedBimBridgeReleaseManifest $manifestPath $signaturePath
        Assert ([bool]$verified.published) 'The verified preview release is not published.'
        $tamperedPath = Join-Path $temporaryRoot 'tampered-release-manifest.json'
        $tamperedText = (Get-Content -LiteralPath $manifestPath -Raw).Replace('"channel": "preview"','"channel": "tampered"')
        [IO.File]::WriteAllText($tamperedPath,$tamperedText,[Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { Read-VerifiedBimBridgeReleaseManifest $tamperedPath $signaturePath | Out-Null } catch { $rejected = $true }
        Assert $rejected 'A tampered release manifest passed detached-signature verification.'
    }

    Invoke-Test 'fresh machine reports not_installed' {
        $status = Invoke-Status (Join-Path $temporaryRoot 'fresh')
        Assert ($status.status -eq 'not_installed') "Expected not_installed, received $($status.status)."
    }

    Invoke-Test 'preflight skips an incompatible runtime without blocking compatible products' {
        $caseRoot = Join-Path $temporaryRoot 'uncertified-revit-runtime'
        $install = Join-Path $caseRoot 'program-files\Autodesk\Revit 2026'
        $compatibleInstall = Join-Path $caseRoot 'program-files\Autodesk\Revit 2027'
        New-Item -ItemType Directory -Force -Path $install,$compatibleInstall | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $install 'RevitAPI.runtimeconfig.json'),
            '{"runtimeOptions":{"tfm":"net8.0"}}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            (Join-Path $compatibleInstall 'RevitAPI.runtimeconfig.json'),
            '{"runtimeOptions":{"tfm":"net10.0"}}',
            [Text.UTF8Encoding]::new($false))
        $status = Invoke-Status $caseRoot
        Assert ($status.status -eq 'not_installed' -and $status.recommendedAction -eq 'install') "Expected install to remain available, received $($status.status)."
        Assert (@($status.prerequisiteIssues).Count -eq 0) 'An incompatible product was treated as a global prerequisite failure.'
        Assert (@($status.compatibilityIssues | Where-Object { $_ -like '*revit 2026*net8.0-windows*not certified*net10.0-windows*' }).Count -eq 1) 'Preflight did not explain the exact skipped Revit runtime.'
        Assert (@($status.skippedProducts | Where-Object { $_.product -eq 'revit' -and $_.version -eq '2026' }).Count -eq 1) 'Preflight did not return the skipped Revit product.'
        $revit = @($status.products.revit | Where-Object version -eq '2026')[0]
        $compatibleRevit = @($status.products.revit | Where-Object version -eq '2027')[0]
        Assert ($revit.targetFramework -eq 'net8.0-windows' -and -not [bool]$revit.certified) 'Preflight did not return exact runtime certification evidence.'
        Assert ([bool]$compatibleRevit.certified) 'The compatible Revit version was not allowed to continue.'
    }

    Invoke-Test 'audit-only state directory is not a partial installation' {
        $caseRoot = Join-Path $temporaryRoot 'audit-only'
        $journal = Join-Path $caseRoot 'local\BIM Bridge\journal'
        New-Item -ItemType Directory -Force -Path $journal | Out-Null
        Set-Content -LiteralPath (Join-Path $journal 'events.jsonl') -Value '{}' -Encoding UTF8
        $status = Invoke-Status $caseRoot
        Assert ($status.status -eq 'not_installed') 'An audit-only directory was treated as a broken install.'
    }

    Invoke-Test 'partial host reports needs_repair' {
        $caseRoot = Join-Path $temporaryRoot 'partial'
        New-Item -ItemType Directory -Force -Path (Join-Path $caseRoot 'local\BIM Bridge\host') | Out-Null
        $status = Invoke-Status $caseRoot
        Assert ($status.status -eq 'needs_repair') 'A partial host did not require repair.'
    }

    Invoke-Test 'unsupported state schema reports needs_repair' {
        $caseRoot = Join-Path $temporaryRoot 'old-schema'
        $stateRoot = Join-Path $caseRoot 'local\BIM Bridge'
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
        @{ schemaVersion=3; version='2.0.0-alpha.2' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'install-state.json') -Encoding UTF8
        $status = Invoke-Status $caseRoot
        Assert ($status.status -eq 'needs_repair') 'An unsupported state schema was accepted.'
    }

    Invoke-Test 'restart comparison preserves UTC JSON timestamps' {
        $caseRoot = Join-Path $temporaryRoot 'restart-time'
        $stateRoot = Join-Path $caseRoot 'local\BIM Bridge'
        $installedFile = Join-Path $stateRoot 'host\2.0.0-alpha.2\mcp-server\aec_mcp_server.py'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installedFile) | Out-Null
        Set-Content -LiteralPath $installedFile -Value 'healthy' -Encoding UTF8
        $hash = (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash.ToLowerInvariant()
        [ordered]@{
            schemaVersion=4; version='2.0.0-alpha.2'; installedAtUtc='2026-08-11T20:00:00Z'
            restartRequired=$true; localMcpServer=$installedFile; python=$installedFile; launcher=$installedFile
            ownedPaths=@($installedFile); files=@([ordered]@{ path=$installedFile; sha256=$hash })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stateRoot 'install-state.json') -Encoding UTF8

        $restarted = Invoke-Status $caseRoot '2026-08-11T20:01:00Z' $true
        Assert ($restarted.status -eq 'healthy') "Expected healthy after restart, received $($restarted.status)."

        $notRestarted = Invoke-Status $caseRoot '2026-08-11T19:59:00Z' $true
        Assert ($notRestarted.status -eq 'restart_required') "Expected restart_required, received $($notRestarted.status)."
    }

    Invoke-Test 'host installer refuses mutation without approval' {
        $message = $null
        try { & $hostInstaller } catch { $message = $_.Exception.Message }
        Assert ($message -like '*explicit approval*') 'Installer did not enforce explicit approval.'
    }

    Invoke-Test 'matrix exposes only certified current baselines' {
        [xml]$matrix = Get-Content -LiteralPath $matrixPath -Raw
        $revit = @($matrix.Project.Choose.When | ForEach-Object { $_.PropertyGroup } |
            Where-Object { $_.PSObject.Properties['RevitCertificationStatus'] -and $_.RevitCertificationStatus -eq 'certified' })
        . (Join-Path $repoRoot 'eng\AutodeskVersionMatrix.ps1')
        $autoCADEntries = @(Get-AutoCADMatrixEntries $matrixPath)
        $autocad = @($autoCADEntries | Where-Object { $_.CertificationStatus -eq 'certified' })
        Assert ($revit.Count -eq 4) "Expected four certified Revit entries, received $($revit.Count)."
        Assert ($autocad.Count -eq 4) "Expected four certified AutoCAD entries, received $($autocad.Count)."
        Assert ($autoCADEntries.Count -eq 4) "Expected four AutoCAD matrix entries, received $($autoCADEntries.Count)."
        foreach ($entry in $revit) {
            Assert ([string]$entry.RevitAssemblyName -eq "BimBridge.Revit$([string]$entry.ReleaseYear)") "Revit $([string]$entry.ReleaseYear) DLL is not BIM Bridge branded."
            Assert (-not [string]::IsNullOrWhiteSpace([string]$entry.RevitCertifiedTargetFrameworks)) "Revit $([string]$entry.ReleaseYear) has no certified target framework."
        }
        foreach ($entry in $autocad) {
            Assert ([string]$entry.AssemblyName -eq "BimBridge.AutoCAD$([string]$entry.Include)") "AutoCAD $([string]$entry.Include) DLL is not BIM Bridge branded."
            Assert (-not [string]::IsNullOrWhiteSpace([string]$entry.CertifiedTargetFrameworks)) "AutoCAD $([string]$entry.Include) has no certified target framework."
        }
        $revit2026 = @($revit | Where-Object ReleaseYear -eq '2026')[0]
        Assert ([string]$revit2026.RevitCertifiedTargetFrameworks -eq 'net10.0-windows') 'Revit 2026 certification is not scoped to its tested .NET 10 runtime.'
    }

    Invoke-Test 'new Autodesk payload contains no AEC Codex assembly identities' {
        $revitProperties = Get-Content -LiteralPath (Join-Path $repoRoot 'src\BimBridge.Revit\BimBridge.Revit.Adapter.props') -Raw
        $hostProject = Get-Content -LiteralPath (Join-Path $repoRoot 'src\BimBridge.Host\BimBridge.Host.csproj') -Raw
        $autoCADProject = Get-Content -LiteralPath (Join-Path $repoRoot 'src\BimBridge.AutoCAD\BimBridge.AutoCAD.Adapter.props') -Raw
        $autoCADPackage = Get-Content -LiteralPath (Join-Path $repoRoot 'src\BimBridge.AutoCAD\PackageContents.template.xml') -Raw
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($revitProperties -match '<AssemblyName>\$\(RevitAssemblyName\)</AssemblyName>') 'Revit assembly identity does not come from the BIM Bridge matrix.'
        Assert ($hostProject -match '<AssemblyName>BimBridge\.Host</AssemblyName>') 'Host bridge DLL is not BIM Bridge branded.'
        Assert ($autoCADProject -match '<AssemblyName>\$\(AutoCADAssemblyName\)</AssemblyName>') 'AutoCAD assembly identity does not come from the BIM Bridge matrix.'
        Assert ($autoCADPackage -match '\{\{COMPONENTS\}\}') 'AutoCAD package is not generated from matrix components.'
        Assert ($installerText -notmatch '"Aec\.Codex\.Revit\$\(\$revit\.Include\)\.dll"') 'BIM Bridge installer still expects an AEC Codex Revit DLL.'
    }

    Invoke-Test 'generic Autodesk matrix helper resolves AutoCAD 2024' {
        . (Join-Path $repoRoot 'eng\AutodeskVersionMatrix.ps1')
        $entry = @(Get-AutoCADMatrixEntries $matrixPath | Where-Object { $_.Include -eq '2024' })[0]
        $resolved = Resolve-AutoCADMatrixEntry $entry (Join-Path $temporaryRoot 'matrix-program-files')
        Assert ($resolved.TargetFramework -eq 'net48') 'AutoCAD 2024 target framework was not resolved from the matrix.'
        Assert ($resolved.Executable -like '*Autodesk\AutoCAD 2024\acad.exe') 'AutoCAD executable path was not derived from the matrix.'
    }

    Invoke-Test 'AutoCAD runtime resolver follows installed API metadata' {
        . (Join-Path $repoRoot 'eng\AutodeskVersionMatrix.ps1')
        $programFiles = Join-Path $temporaryRoot 'autocad-runtime-program-files'
        $install = Join-Path $programFiles 'Autodesk\AutoCAD 2026'
        New-Item -ItemType Directory -Force -Path $install | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'acdbmgd.runtimeconfig.json'), '{"runtimeOptions":{"tfm":"net10.0"}}', [Text.UTF8Encoding]::new($false))
        $entry = @(Get-AutoCADMatrixEntries $matrixPath | Where-Object { $_.Include -eq '2026' })[0]
        $resolved = Resolve-AutoCADMatrixEntry $entry $programFiles
        Assert ($resolved.TargetFramework -eq 'net10.0-windows') 'AutoCAD 2026 installed .NET 10 runtime was not resolved.'
        Assert ($resolved.DetectedRuntime -eq 'net10.0') 'AutoCAD 2026 runtime evidence was not retained.'
    }

    Invoke-Test 'installer detects installed Autodesk products before runtime resolution' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($installerText -match 'candidateExecutable.*Revit\.exe') 'Revit detection does not precede runtime resolution.'
        Assert ($installerText -match 'candidateExecutable.*acad\.exe') 'AutoCAD detection does not precede runtime resolution.'
        Assert ($installerText -match 'Resolve-RevitMatrixEntry\s+\$entry\s+-RequireCertified') 'Installer does not reject uncertified Revit runtime variants before staging.'
        Assert ($installerText -match 'Resolve-AutoCADMatrixEntry\s+\$entry\s+-RequireCertified') 'Installer does not identify uncertified AutoCAD runtime variants before staging.'
        Assert ($installerText -match 'Add-SkippedProduct') 'Installer does not record incompatible installed products as skipped.'
        Assert ($installerText -match 'skippedProducts=@\(\$skippedProducts\)') 'Installer result does not expose skipped products.'
        Assert ($installerText -match 'knownRevitManifestPaths') 'Installer does not transactionally remove stale manifests for skipped Revit versions.'
    }

    Invoke-Test 'migration preserves the legacy state root itself' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($installerText -notmatch 'Backup-Path\s+\$legacyStateRoot') 'Migration targets the entire legacy state root.'
        Assert ($installerText -match '\$legacyInstallState') 'Migration does not target the known legacy install-state file.'
    }

    Invoke-Test 'MCP registrations participate in rollback' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($installerText -match 'previousNewMcp\s*=\s*Get-CodexMcp') 'The previous BIM Bridge MCP registration is not captured.'
        Assert ($installerText -match 'Restore-CodexMcp\s+\$codexCli\s+\$newMcpName\s+\$previousNewMcp') 'The previous BIM Bridge MCP registration is not restored on failure.'
        Assert ($installerText -match 'previousLegacyMcp\s*=\s*Get-CodexMcp') 'The previous legacy MCP registration is not captured.'
    }

    Invoke-Test 'repair can reuse the installed private runtime' {
        $installerText = Get-Content -LiteralPath $mainInstaller -Raw
        Assert ($installerText -match '\$currentState\s+-and\s+\$currentState\.python') 'Repair cannot source the current private Python runtime.'
        Assert ($installerText -match "integrityScope='critical-runtime-and-adapter-files'") 'The installer does not declare its bounded integrity scope.'
        Assert ($installerText -notmatch 'New-FileRecords\s+\$ownedPaths') 'Integrity checks still hash every private runtime file.'
        Assert ($installerText -match 'Remove-StaleTransactionDirectories\s+\$stateRoot') 'Successful repair does not clean safely scoped stale transaction directories.'
        Assert ($installerText -match '\[IO\.Directory\]::EnumerateFiles\(\$extended') 'Transaction cleanup does not support Windows extended-length paths.'
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe cleanup target: $resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
