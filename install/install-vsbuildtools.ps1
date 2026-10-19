<#
.SYNOPSIS
    Silently install Visual Studio 2022 Build Tools with Desktop C++.

.DESCRIPTION
    Same switches as the vendor cmd: VCTools + includeRecommended.
    Adds --wait so AIB does not continue before setup finishes.

.PARAMETER SourcePath
    Folder that contains vs_BuildTools.exe
    Default: same directory as this script.

.EXAMPLE
    .\install-vsbuildtools.ps1 -SourcePath '\\share\installers\vsbuildtools'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$SourcePath,
    [string]$InstallerName = 'vs_BuildTools.exe',
    [string]$InstallPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$AppName = 'VS 2022 Build Tools'

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    if (-not $script:LogPath) {
        $script:LogPath = Join-Path $env:TEMP ("SoftwareInstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    }

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    $dir = Split-Path $script:LogPath -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Test-InstallerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string[]]$ExpectedPublishers,
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Log ('SHA256 {0}' -f $actualHash)

    if ($ExpectedSha256) {
        $expected = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualHash -ne $expected) {
            throw "SHA-256 mismatch. Expected $expected but got $actualHash"
        }
        Write-Log 'SHA-256 verified' -Level SUCCESS
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        Write-Log ('Package is not signed ({0}); continuing' -f $sig.Status) -Level WARN
        return
    }

    if ($ExpectedPublishers -and $sig.SignerCertificate) {
        $subject = $sig.SignerCertificate.Subject
        $matched = $false
        foreach ($pub in $ExpectedPublishers) {
            if ($subject -like "*$pub*") { $matched = $true; break }
        }
        if (-not $matched) {
            throw "Unexpected publisher. Subject='$subject'"
        }
        Write-Log 'Publisher matched' -Level SUCCESS
    }
}

function Get-InstalledVsBuildTools {
    $paths = @(
        (Join-Path $InstallPath 'MSBuild\Current\Bin\MSBuild.exe'),
        (Join-Path $InstallPath 'VC\Auxiliary\Build\vcvars64.bat'),
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
    )
    foreach ($p in $paths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return $p
        }
    }
    return $null
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-VSBuildTools_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

if (-not $SourcePath) {
    $SourcePath = $PSScriptRoot
}

Write-Log ('Starting {0} install' -f $AppName)

try {
    $installed = Get-InstalledVsBuildTools
    if ($installed -and -not $Force) {
        Write-Log ('Already installed: {0}' -f $installed) -Level SUCCESS
        if (Test-Path -LiteralPath $InstallPath) {
            [Environment]::SetEnvironmentVariable('VS2022INSTALLDIR', $InstallPath, 'Machine')
            $env:VS2022INSTALLDIR = $InstallPath
            Write-Log 'VS2022INSTALLDIR set'
        }
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    $setup = Join-Path $SourcePath $InstallerName
    if (-not (Test-Path -LiteralPath $setup)) {
        throw "vs_BuildTools.exe not found: $setup"
    }

    $integrityParams = @{
        Path               = $setup
        ExpectedPublishers = @('Microsoft')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Installing VS Build Tools VCTools'
    $argLine = '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --installWhileDownloading --installPath "{0}" --nocache' -f $InstallPath
    Write-Log $argLine
    $installerParams = @{
        FilePath     = $setup
        ArgumentList = $argLine
        Wait         = $true
        PassThru     = $true
        WindowStyle  = 'Hidden'
    }
    $process = Start-Process @installerParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw ('Installer exit code {0}' -f $process.ExitCode)
    }

    $newVersion = Get-InstalledVsBuildTools
    if ($newVersion) {
        Write-Log ('Installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer finished but Build Tools were not detected' -Level WARN
    }

    if (Test-Path -LiteralPath $InstallPath) {
        Write-Log 'Setting VS2022INSTALLDIR system variable'
        [Environment]::SetEnvironmentVariable('VS2022INSTALLDIR', $InstallPath, 'Machine')
        $env:VS2022INSTALLDIR = $InstallPath
    }
    else {
        Write-Log 'Install path not found; VS2022INSTALLDIR was not set' -Level WARN
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
