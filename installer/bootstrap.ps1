[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseZipUri,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$Sha256,
    [ValidateSet('HostOnly', 'Development')]
    [string]$InstallMode = 'HostOnly',
    [switch]$UserApproved
)

$ErrorActionPreference = 'Stop'
if (-not $UserApproved) {
    throw 'AEC Codex installation requires explicit user approval. Review the release URL, SHA-256, and install locations before rerunning with -UserApproved.'
}
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('aec-codex-' + [Guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $temporaryRoot 'release.zip'
$extractPath = Join-Path $temporaryRoot 'release'
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    if (Test-Path -LiteralPath $ReleaseZipUri -PathType Leaf) {
        Copy-Item -LiteralPath $ReleaseZipUri -Destination $zipPath -Force
    } else {
        Invoke-WebRequest -Uri ([uri]$ReleaseZipUri) -OutFile $zipPath -UseBasicParsing
    }
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actual -ne $Sha256.ToUpperInvariant()) { throw "Release checksum mismatch. Expected $Sha256, received $actual." }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    $installer = Get-ChildItem -LiteralPath $extractPath -Filter Install-AecCodex.ps1 -File -Recurse | Select-Object -First 1
    if (-not $installer) { throw 'The release does not contain Install-AecCodex.ps1.' }
    & $installer.FullName -SourceRoot (Split-Path -Parent $installer.DirectoryName) -InstallMode $InstallMode -SkipBuild
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe bootstrap cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
