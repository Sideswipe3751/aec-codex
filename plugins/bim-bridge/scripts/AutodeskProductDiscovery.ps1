Set-StrictMode -Version 2.0

function Get-AutodeskRegistryInstallRecords {
    if ($env:OS -ne 'Windows_NT') { return @() }

    $records = New-Object System.Collections.ArrayList
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryHive]::CurrentUser)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $baseKey = $null
            $uninstallKey = $null
            try {
                $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $uninstallKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
                if (-not $uninstallKey) { continue }
                foreach ($subKeyName in @($uninstallKey.GetSubKeyNames())) {
                    $productKey = $null
                    try {
                        $productKey = $uninstallKey.OpenSubKey($subKeyName)
                        if (-not $productKey) { continue }
                        $displayName = [string]$productKey.GetValue('DisplayName', '')
                        $installLocation = [string]$productKey.GetValue('InstallLocation', '')
                        if ([string]::IsNullOrWhiteSpace($displayName) -or [string]::IsNullOrWhiteSpace($installLocation)) { continue }
                        [void]$records.Add([pscustomobject]@{
                            DisplayName = $displayName
                            InstallLocation = $installLocation
                            RegistryHive = [string]$hive
                            RegistryView = [string]$view
                            RegistryKey = $subKeyName
                        })
                    } catch { } finally {
                        if ($productKey) { $productKey.Dispose() }
                    }
                }
            } catch { } finally {
                if ($uninstallKey) { $uninstallKey.Dispose() }
                if ($baseKey) { $baseKey.Dispose() }
            }
        }
    }
    return @($records)
}

function Get-AutodeskProductPathOverride(
    [System.Collections.IDictionary]$ProductInstallPathOverrides,
    [string]$Product,
    [string]$Version
) {
    if (-not $ProductInstallPathOverrides) { return $null }
    $key = $Product.ToLowerInvariant() + ':' + $Version
    if (-not $ProductInstallPathOverrides.Contains($key)) { return $null }
    return [string]$ProductInstallPathOverrides[$key]
}

function ConvertTo-AutodeskInstallDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $candidate = $Path.Trim().Trim('"')
    try { return [IO.Path]::GetFullPath($candidate).TrimEnd('\') } catch { return $null }
}

function Test-AutodeskInstallDirectory(
    [string]$Path,
    [string]$ExecutableName,
    [string]$ApiAssemblyName
) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path $ExecutableName) -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path $ApiAssemblyName) -PathType Leaf)) { return $false }
    return $true
}

function Resolve-AutodeskProductInstallation {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('revit','autocad')]
        [string]$Product,
        [Parameter(Mandatory=$true)]
        [string]$Version,
        [Parameter(Mandatory=$true)]
        [string]$InstallSubdirectory,
        [string[]]$ProgramFilesRoots,
        [System.Collections.IDictionary]$ProductInstallPathOverrides,
        [object[]]$RegistryInstallRecords
    )

    $executableName = if ($Product -eq 'revit') { 'Revit.exe' } else { 'acad.exe' }
    $apiAssemblyName = if ($Product -eq 'revit') { 'RevitAPI.dll' } else { 'AcCoreMgd.dll' }
    $override = Get-AutodeskProductPathOverride $ProductInstallPathOverrides $Product $Version
    if ($override) {
        $installDirectory = ConvertTo-AutodeskInstallDirectory $override
        if (-not (Test-AutodeskInstallDirectory $installDirectory $executableName $apiAssemblyName)) {
            throw "The explicit $Product $Version installation path is invalid. Expected $executableName and $apiAssemblyName under: $override"
        }
        return [pscustomobject]@{
            Product = $Product
            Version = $Version
            InstallDirectory = $installDirectory
            Executable = Join-Path $installDirectory $executableName
            ApiAssembly = Join-Path $installDirectory $apiAssemblyName
            Source = 'override'
            RegistryDisplayName = $null
        }
    }

    if ($null -eq $RegistryInstallRecords) { $RegistryInstallRecords = @(Get-AutodeskRegistryInstallRecords) }
    $productPattern = if ($Product -eq 'revit') { '\bRevit\b' } else { '\bAutoCAD\b' }
    $versionPattern = '\b' + [Regex]::Escape($Version) + '\b'
    foreach ($record in @($RegistryInstallRecords)) {
        $displayName = [string]$record.DisplayName
        if ($displayName -notmatch $productPattern -or $displayName -notmatch $versionPattern) { continue }
        $installDirectory = ConvertTo-AutodeskInstallDirectory ([string]$record.InstallLocation)
        if (-not (Test-AutodeskInstallDirectory $installDirectory $executableName $apiAssemblyName)) { continue }
        return [pscustomobject]@{
            Product = $Product
            Version = $Version
            InstallDirectory = $installDirectory
            Executable = Join-Path $installDirectory $executableName
            ApiAssembly = Join-Path $installDirectory $apiAssemblyName
            Source = 'registry'
            RegistryDisplayName = $displayName
        }
    }

    foreach ($root in @($ProgramFilesRoots)) {
        if (-not $root) { continue }
        $installDirectory = ConvertTo-AutodeskInstallDirectory (Join-Path $root $InstallSubdirectory)
        if (-not (Test-AutodeskInstallDirectory $installDirectory $executableName $apiAssemblyName)) { continue }
        return [pscustomobject]@{
            Product = $Product
            Version = $Version
            InstallDirectory = $installDirectory
            Executable = Join-Path $installDirectory $executableName
            ApiAssembly = Join-Path $installDirectory $apiAssemblyName
            Source = 'standard-path'
            RegistryDisplayName = $null
        }
    }
    return $null
}
