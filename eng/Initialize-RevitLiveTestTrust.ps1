[CmdletBinding()]
param(
    [ValidateRange(1, 3)]
    [int]$YearsValid = 1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$subject = 'CN=BIM Bridge Revit Live Test Development'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'BIM Bridge\development-trust'
$statePath = Join-Path $stateDirectory 'revit-live-test-signing.json'
$publicCertificatePath = Join-Path $stateDirectory 'revit-live-test-signing.cer'

if (@(Get-Process Revit -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close every Revit process before changing the live-test signing trust.'
}

$minimumExpiry = [DateTime]::UtcNow.AddDays(30)
$certificate = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object {
        $_.Subject -eq $subject -and
        $_.HasPrivateKey -and
        $_.NotAfter.ToUniversalTime() -gt $minimumExpiry
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1)

$created = $false
if ($certificate.Count -eq 0) {
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $subject `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -HashAlgorithm SHA256 `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -KeyExportPolicy NonExportable `
        -NotAfter ([DateTime]::Now.AddYears($YearsValid)) `
        -FriendlyName 'BIM Bridge Revit live-test development signing'
    $created = $true
} else {
    $certificate = $certificate[0]
}

if (-not $certificate.HasPrivateKey) { throw 'The development signing certificate has no private key.' }
if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
}

Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force | Out-Null
foreach ($store in @('Cert:\CurrentUser\Root', 'Cert:\CurrentUser\TrustedPublisher')) {
    $existing = Get-ChildItem -LiteralPath $store | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint }
    if (-not $existing) {
        Import-Certificate -FilePath $publicCertificatePath -CertStoreLocation $store | Out-Null
    }
}

foreach ($store in @('Cert:\CurrentUser\Root', 'Cert:\CurrentUser\TrustedPublisher')) {
    if (-not (Get-ChildItem -LiteralPath $store | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint })) {
        throw "Certificate trust verification failed for $store."
    }
}

$state = [ordered]@{
    schemaVersion = 1
    purpose = 'revit-live-test-development-signing'
    subject = $certificate.Subject
    thumbprint = $certificate.Thumbprint
    createdThisRun = $created
    privateKeyExported = $false
    privateKeyStore = 'Cert:\CurrentUser\My'
    trustedStores = @('Cert:\CurrentUser\Root', 'Cert:\CurrentUser\TrustedPublisher')
    publicCertificatePath = $publicCertificatePath
    notBeforeUtc = $certificate.NotBefore.ToUniversalTime().ToString('o')
    notAfterUtc = $certificate.NotAfter.ToUniversalTime().ToString('o')
    configuredAtUtc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$state | ConvertTo-Json -Depth 5
