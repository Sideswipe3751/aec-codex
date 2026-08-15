[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\') + '\'
$statePath = Join-Path $env:LOCALAPPDATA 'BIM Bridge\development-trust\revit-live-test-signing.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "Revit live-test development trust is not initialized: $statePath"
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.purpose -ne 'revit-live-test-development-signing' -or -not $state.thumbprint) {
    throw 'Revit live-test development trust state is invalid.'
}

$certificate = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + [string]$state.thumbprint) -ErrorAction Stop
if (-not $certificate.HasPrivateKey) { throw 'The configured development signing certificate has no private key.' }
if ($certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) { throw 'The configured development signing certificate is expired.' }
foreach ($store in @('Cert:\CurrentUser\Root', 'Cert:\CurrentUser\TrustedPublisher')) {
    if (-not (Get-ChildItem -LiteralPath $store | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint })) {
        throw "The development signing certificate is not trusted in $store."
    }
}

$results = @()
foreach ($item in $Path) {
    $resolved = [IO.Path]::GetFullPath($item)
    if (-not $resolved.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to sign a file outside the repository: $resolved"
    }
    if ([IO.Path]::GetExtension($resolved) -ne '.dll') { throw "Only DLL artifacts may be signed: $resolved" }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Signing target does not exist: $resolved" }

    $signature = Set-AuthenticodeSignature -LiteralPath $resolved -Certificate $certificate -HashAlgorithm SHA256
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode signing did not produce a valid signature for ${resolved}: $($signature.Status) $($signature.StatusMessage)"
    }
    $results += [ordered]@{
        path = $resolved
        status = [string]$signature.Status
        thumbprint = $certificate.Thumbprint
        subject = $certificate.Subject
    }
}
$results | ConvertTo-Json -Depth 4
