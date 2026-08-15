Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'RevitVersionMatrix.ps1')

function Get-AutoCADMatrixEntries([string]$MatrixPath) {
    [xml]$matrix = Get-Content -LiteralPath $MatrixPath -Raw
    @($matrix.Project.ItemGroup.AutoCADRelease | ForEach-Object {
        [pscustomobject]@{
            Include = [string]$_.Include
            AssemblyName = [string]$_.AssemblyName
            TargetFramework = [string]$_.TargetFramework
            RuntimeFamily = [string]$_.RuntimeFamily
            SupportStatus = [string]$_.SupportStatus
            CertificationStatus = [string]$_.CertificationStatus
            InstallSubdirectory = [string]$_.InstallSubdirectory
        }
    })
}

function Resolve-AutoCADMatrixEntry(
    [object]$Release,
    [string]$ProgramFilesPath = $env:ProgramFiles
) {
    $installDirectory = Join-Path $ProgramFilesPath ([string]$Release.InstallSubdirectory)
    [pscustomobject]@{
        Include = [string]$Release.Include
        AssemblyName = [string]$Release.AssemblyName
        TargetFramework = [string]$Release.TargetFramework
        RuntimeFamily = [string]$Release.RuntimeFamily
        SupportStatus = [string]$Release.SupportStatus
        CertificationStatus = [string]$Release.CertificationStatus
        InstallDirectory = $installDirectory
        Executable = Join-Path $installDirectory 'acad.exe'
    }
}
