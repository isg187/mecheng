<#
.SYNOPSIS
    Silently install Siemens Designcenter NX from vendor media.

.DESCRIPTION
    Runs Setup.exe the same way as autoinstall.cmd.
    Point -SourcePath at the extracted vendor folder (or the file share
    copy). Does not download NX from the internet.

.PARAMETER SourcePath
    Folder that contains SiemensDesigncenterNX-2512.7001_wntx64\designcenternx\Setup.exe
    Default: same directory as this script.

.PARAMETER Force
    Reinstall even if NX is already present.

.EXAMPLE
    .\install-nx.ps1 -SourcePath '\\staccount.file.core.usgovcloudapi.net\installers\nx'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$SourcePath,
    [string]$InstallDir = 'C:\Program Files\Siemens\NX',
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$AppName = 'Siemens NX'
$SetupRelative = Join-Path 'SiemensDesigncenterNX-2512.7001_wntx64' 'designcenternx\Setup.exe'

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

function Get-InstalledNx {
    $markers = @(
        (Join-Path $InstallDir 'UGII\ugraf.exe'),
        (Join-Path $InstallDir 'NXBIN\ugraf.exe'),
        (Join-Path $InstallDir 'ugraf.exe')
    )
    foreach ($exe in $markers) {
        if (Test-Path -LiteralPath $exe) {
            return (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        }
    }
    if (Test-Path -LiteralPath $InstallDir) {
        return $InstallDir
    }
    return $null
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-NX_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

if (-not $SourcePath) {
    $SourcePath = $PSScriptRoot
}

Write-Log ('Starting {0} install' -f $AppName)

try {
    $installed = Get-InstalledNx
    if ($installed -and -not $Force) {
        Write-Log ('Already installed: {0}' -f $installed) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    $setup = Join-Path $SourcePath $SetupRelative
    if (-not (Test-Path -LiteralPath $setup)) {
        throw "Setup.exe not found: $setup"
    }

    $integrityParams = @{
        Path               = $setup
        ExpectedPublishers = @('Siemens')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    $setupLog = Join-Path $env:TEMP 'NX_Silent_Install.log'
    $msiArgs = '/qn /norestart /L*v \"{0}\" INSTALLDIR=\"{1}\"' -f $setupLog, $InstallDir
    $argumentList = '/s /v"{0}"' -f $msiArgs

    Write-Log 'Installing NX'
    $installerParams = @{
        FilePath     = $setup
        ArgumentList = $argumentList
        Wait         = $true
        PassThru     = $true
        WindowStyle  = 'Hidden'
    }
    $process = Start-Process @installerParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw ('Installer exit code {0}' -f $process.ExitCode)
    }

    $newVersion = Get-InstalledNx
    if ($newVersion) {
        Write-Log ('Installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer finished but NX was not detected' -Level WARN
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
