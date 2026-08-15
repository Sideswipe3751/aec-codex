[CmdletBinding()]
param(
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SourceRoot = Split-Path -Parent (Split-Path -Parent $scriptDirectory)
}

$listingPath = Join-Path $SourceRoot 'submission\listing.json'
$listing = Get-Content -LiteralPath $listingPath -Raw | ConvertFrom-Json
if ([string]$listing.logoStatus -ne 'owner-selected-transparent') {
    throw 'The public listing does not mark the owner-selected logo as ready.'
}
$logoPath = Join-Path $SourceRoot ([string]$listing.logoPath)
if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf) -or [IO.Path]::GetExtension($logoPath) -ne '.png') {
    throw "The public listing logo is missing or is not PNG: $logoPath"
}

Add-Type -AssemblyName System.Drawing
$image = New-Object Drawing.Bitmap($logoPath)
try {
    if ($image.Width -ne $image.Height -or $image.Width -lt 512) {
        throw "The public listing logo must be square and at least 512 px; found $($image.Width)x$($image.Height)."
    }
    $lastX = $image.Width - 1
    $lastY = $image.Height - 1
    $midX = [int]($lastX / 2)
    $midY = [int]($lastY / 2)
    foreach ($point in @(
        @(0,0), @($lastX,0), @(0,$lastY), @($lastX,$lastY),
        @($midX,0), @($midX,$lastY), @(0,$midY), @($lastX,$midY)
    )) {
        if ($image.GetPixel($point[0], $point[1]).A -ne 0) {
            throw "The public listing logo still has a non-transparent exterior pixel at $($point[0]),$($point[1])."
        }
    }
    if ($image.GetPixel($midX, $midY).A -ne 255) {
        throw 'The public listing logo center is unexpectedly transparent.'
    }
    Write-Host "PASS public listing logo is $($image.Width)x$($image.Height) RGBA with transparent exterior pixels."
} finally {
    $image.Dispose()
}
