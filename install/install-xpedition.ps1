<#
.SYNOPSIS
    Silently install Siemens Xpedition Enterprise 2504 from vendor media.

.DESCRIPTION
    Replaces the MIP autoinstall.cmd. Media comes from -SourcePath
    (installer file share), not \\jupiter.
    Writes a local MIP batch file with the same product list, runs
    setup.exe -noexecute, then Install.exe -batch.

.PARAMETER SourcePath
    Extracted vendor folder that contains setup.exe
    Example: \\staccount.file.core.usgovcloudapi.net\installers\xpedition\Xpedition-Enterprise_2504_win64

.PARAMETER LicenseServer
    SALT license string. Example: 29001@bast
    Leave blank to skip license env.

.PARAMETER CorporateWdirSource
    Optional file to copy into C:\WDIR\XENTP2504\DxDesigner.xml

.EXAMPLE
    .\install-xpedition.ps1 -SourcePath '\\share\installers\xpedition\Xpedition-Enterprise_2504_win64'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$SourcePath,
    [string]$TargetPath = 'C:\SiemensEDA',
    [string]$WdirPath = 'C:\WDIR\XENTP2504',
    [string]$LicenseServer,
    [string]$CorporateWdirSource,
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$AppName = 'Xpedition Enterprise'
$ReleaseRoot = 'XENTP2504'

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

function Get-InstalledXpedition {
    $markers = @(
        (Join-Path $TargetPath "$ReleaseRoot\SDD_HOME"),
        (Join-Path $TargetPath $ReleaseRoot)
    )
    foreach ($p in $markers) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-SiemensInstallExe {
    $keyPaths = @(
        'HKLM:\SOFTWARE\Siemens\SiemensJI',
        'HKLM:\SOFTWARE\WOW6432Node\Siemens\SiemensJI'
    )
    foreach ($key in $keyPaths) {
        $inst = (Get-ItemProperty $key -ErrorAction SilentlyContinue).InstPath
        if ($inst) {
            $exe = Join-Path $inst 'Install.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    return $null
}

function New-MipBatchFile {
    param(
        [string]$Path,
        [string]$Src,
        [string]$Tgt
    )

    $xml = @"
@echo off
REM MIP batch generated for AIB. Product list matches vendor autoinstall.
REM ##### BELOW HERE IS XML DATA #####
<batchFile>
	<source value="$Src"/>
	<target value="$Tgt"/>
	<installType value="all"/>
	<platform value="Windows 64-bit"/>
	<release name="Xpedition Enterprise 2504">
		<product name="3D Plug-in" productroot="XENTP2504"/>
		<product name="Layout Browser" productroot="XENTP2504"/>
		<product name="Smart Utilities" productroot="XENTP2504"/>
		<product name="Xpedition Designer" productroot="XENTP2504"/>
		<product name="Xpedition FPGA I/O Optimizer" productroot="XENTP2504"/>
		<product name="Xpedition FabLink" productroot="XENTP2504"/>
		<product name="Xpedition Layout" productroot="XENTP2504"/>
		<product name="iCDB Server Monitor" productroot="XENTP2504"/>
	</release>
</batchFile>
"@
    Set-Content -Path $Path -Value $xml -Encoding ASCII
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-Xpedition_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

if (-not $SourcePath) {
    $SourcePath = $PSScriptRoot
}

Write-Log ('Starting {0} install' -f $AppName)

try {
    $env:LC_ALL = 'en_US'
    try { chcp 65001 | Out-Null } catch { }

    $installed = Get-InstalledXpedition
    if ($installed -and -not $Force) {
        Write-Log ('Already installed: {0}' -f $installed) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    $setup = Join-Path $SourcePath 'setup.exe'
    if (-not (Test-Path -LiteralPath $setup)) {
        throw "setup.exe not found: $setup"
    }

    $integrityParams = @{
        Path               = $setup
        ExpectedPublishers = @('Siemens', 'Mentor')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Running setup.exe -noexecute'
    $bootstrapParams = @{
        FilePath     = $setup
        ArgumentList = @('-noexecute')
        Wait         = $true
        PassThru     = $true
        WindowStyle  = 'Hidden'
    }
    $boot = Start-Process @bootstrapParams
    if ($boot.ExitCode -ne 0 -and $boot.ExitCode -ne 3010) {
        throw ('setup.exe -noexecute exit code {0}' -f $boot.ExitCode)
    }

    $installExe = Get-SiemensInstallExe
    if (-not $installExe) {
        throw 'Siemens Install.exe not found after setup -noexecute'
    }

    $batchFile = Join-Path $env:TEMP 'xpedition-mip-batch.cmd'
    New-MipBatchFile -Path $batchFile -Src $SourcePath -Tgt $TargetPath

    Write-Log 'Running MIP Install.exe -batch -silent'
    $eulaFile = Join-Path $env:TEMP 'xpedition-eula-answers.txt'
    Set-Content -Path $eulaFile -Value "d`r`nyes`r`n" -Encoding ASCII
    $mipArgs = '-batch "{0}" -tgt "{1}" -src "{2}" -silent -nosplash' -f $batchFile, $TargetPath, $SourcePath
    $cmdLine = 'type "{0}" | "{1}" {2}' -f $eulaFile, $installExe, $mipArgs
    Write-Log $cmdLine
    $mipParams = @{
        FilePath     = 'cmd.exe'
        ArgumentList = @('/c', $cmdLine)
        Wait         = $true
        PassThru     = $true
        WindowStyle  = 'Hidden'
    }
    $mip = Start-Process @mipParams
    if ($mip.ExitCode -ne 0 -and $mip.ExitCode -ne 3010) {
        throw ('MIP Install.exe exit code {0}' -f $mip.ExitCode)
    }

    $docDir = Join-Path $TargetPath "$ReleaseRoot\SDD_HOME\standard"
    if (-not (Test-Path $docDir)) {
        New-Item -ItemType Directory -Path $docDir -Force | Out-Null
    }
    $docCfg = Join-Path $docDir 'disw_doc.config'
    Set-Content -Path $docCfg -Value "server=https://docs.sw.siemens.com`r`ntype=default" -Encoding ASCII

    if (-not (Test-Path $WdirPath)) {
        New-Item -ItemType Directory -Path $WdirPath -Force | Out-Null
    }

    $instDir = Split-Path $installExe -Parent
    $msiCmd = Join-Path $instDir 'bin\msi_cmd.exe'
    if (Test-Path -LiteralPath $msiCmd) {
        if ($LicenseServer) {
            Write-Log 'Setting SALT_LICENSE_SERVER'
            Start-Process -FilePath $msiCmd -ArgumentList @('-env', 'SALT_LICENSE_SERVER', $LicenseServer, 'R', 'S') -Wait -WindowStyle Hidden
        }
        Write-Log 'Setting WDIR_XENTP2504'
        Start-Process -FilePath $msiCmd -ArgumentList @('-env', 'WDIR_XENTP2504', $WdirPath, 'R', 'S') -Wait -WindowStyle Hidden
    }

    if ($CorporateWdirSource -and (Test-Path -LiteralPath $CorporateWdirSource)) {
        Copy-Item -LiteralPath $CorporateWdirSource -Destination (Join-Path $WdirPath 'DxDesigner.xml') -Force
    }

    $newVersion = Get-InstalledXpedition
    if ($newVersion) {
        Write-Log ('Installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer finished but Xpedition was not detected' -Level WARN
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
