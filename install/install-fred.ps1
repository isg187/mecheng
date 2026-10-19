<#
.SYNOPSIS
    Silently install Photon Engineering FRED from vendor media.

.DESCRIPTION
    Standalone EXE. Default silent switches are NSIS-style (/S /norestart).
    If the installer UI still appears, run the EXE with /? on a test box
    and pass the real switches with -InstallArgs.

.PARAMETER SourcePath
    Folder that contains FRED_25.50.1_x64_Installer.exe
    Default: same directory as this script.

.PARAMETER Force
    Reinstall even if FRED is already present.

.EXAMPLE
    .\install-fred.ps1 -SourcePath '\\staccount.file.core.usgovcloudapi.net\installers\fred'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$SourcePath,
    [string]$InstallerName = 'FRED_25.50.1_x64_Installer.exe',
    [string]$ExpectedSha256,
    [string[]]$InstallArgs
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$AppName = 'FRED'

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

function Get-InstalledFred {
    $root = Join-Path $env:ProgramFiles 'Photon Engineering'
    if (-not (Test-Path -LiteralPath $root)) { return $null }

    $exe = Get-ChildItem $root -Filter 'Fred.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
    Select-Object -First 1
    if ($exe) {
        return $exe.VersionInfo.ProductVersion
    }
    return $root
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-FRED_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

if (-not $SourcePath) {
    $SourcePath = $PSScriptRoot
}

if (-not $InstallArgs) {
    $InstallArgs = @('/S', '/norestart')
}

Write-Log ('Starting {0} install' -f $AppName)

try {
    $installed = Get-InstalledFred
    if ($installed -and -not $Force) {
        Write-Log ('Already installed: {0}' -f $installed) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    $packagePath = Join-Path $SourcePath $InstallerName
    if (-not (Test-Path -LiteralPath $packagePath)) {
        throw "Installer not found: $packagePath"
    }

    $integrityParams = @{
        Path               = $packagePath
        ExpectedPublishers = @('Photon Engineering')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Installing FRED'
    $installerParams = @{
        FilePath     = $packagePath
        ArgumentList = $InstallArgs
        Wait         = $true
        PassThru     = $true
        WindowStyle  = 'Hidden'
    }
    $process = Start-Process @installerParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw ('Installer exit code {0}' -f $process.ExitCode)
    }

    $newVersion = Get-InstalledFred
    if ($newVersion) {
        Write-Log ('Installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer finished but FRED was not detected' -Level WARN
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
