Set-StrictMode -Version 2.0

function Read-VerifiedBimBridgeReleaseManifest(
    [string]$ManifestPath,
    [string]$SignaturePath,
    [string]$CertificateBase64Path
) {
    if (-not $ManifestPath) { throw 'The BIM Bridge release manifest path is required.' }
    if (-not $SignaturePath) { $SignaturePath = $ManifestPath + '.sig' }
    if (-not $CertificateBase64Path) {
        $CertificateBase64Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\release-channel.cer.b64'
    }
    foreach ($required in @($ManifestPath,$SignaturePath,$CertificateBase64Path)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Signed BIM Bridge release input is missing: $required" }
    }

    $certificateBytes = [Convert]::FromBase64String(([IO.File]::ReadAllText($CertificateBase64Path) -replace '\s',''))
    $certificateHash = ([Security.Cryptography.SHA256]::Create().ComputeHash($certificateBytes) |
        ForEach-Object { $_.ToString('x2') }) -join ''
    $expectedCertificateHash = '299ea3f53c7fe0245a2f65c9a55b6bf1e38f89e5c0a501935bdaedb47f35d5cc'
    if ($certificateHash -ne $expectedCertificateHash) { throw 'The pinned BIM Bridge release certificate has changed.' }

    $manifestBytes = [IO.File]::ReadAllBytes($ManifestPath)
    try { $signatureBytes = [Convert]::FromBase64String(([IO.File]::ReadAllText($SignaturePath) -replace '\s','')) }
    catch { throw 'The BIM Bridge release signature is not valid base64.' }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
    if ([DateTime]::UtcNow -lt $certificate.NotBefore.ToUniversalTime() -or [DateTime]::UtcNow -gt $certificate.NotAfter.ToUniversalTime()) {
        $certificate.Dispose()
        throw 'The BIM Bridge release signing certificate is outside its validity window.'
    }
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
    try {
        if (-not $rsa.VerifyData($manifestBytes,$signatureBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
            throw 'BIM Bridge release manifest signature verification failed.'
        }
    } finally {
        if ($rsa) { $rsa.Dispose() }
        $certificate.Dispose()
    }
    [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
}
