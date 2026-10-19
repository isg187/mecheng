<#
.SYNOPSIS
    Silently install Intel Fortran and its required Visual Studio 2022 Build Tools.

.DESCRIPTION
    Installs Microsoft Visual Studio 2022 Build Tools with the Desktop development
    with C++ workload before installing Intel oneAPI Toolkit / Intel Fortran.
    Verifies that Intel Fortran is registered as installed and that ifx.exe exists.

.PARAMETER Force
    Re-run the Intel installer even if Intel Fortran is already installed.

.PARAMETER ExpectedSha256
    Optional SHA-256 for the Intel oneAPI installer. Enforced when supplied.

.EXAMPLE
    .\install-fortran.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'AppInstall'),
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$AppName = 'Intel Fortran Compiler'

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
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
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
        throw ('Package signature is not valid: {0}' -f $sig.Status)
    }

    if ($ExpectedPublishers -and $sig.SignerCertificate) {
        $subject = $sig.SignerCertificate.Subject
        $matched = $false
        foreach ($pub in $ExpectedPublishers) {
            if ($subject -like "*$pub*") {
                $matched = $true
                break
            }
        }
        if (-not $matched) {
            throw "Unexpected publisher. Subject='$subject'"
        }
        Write-Log ('Publisher verified: {0}' -f $subject) -Level SUCCESS
    }
}

function Get-VSWherePath {
    $path = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $path) {
        return $path
    }
    return $null
}

function Get-VSBuildToolsPath {
    $vswhere = Get-VSWherePath
    if (-not $vswhere) {
        return $null
    }

    $path = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $path) {
        return $null
    }

    return ($path | Select-Object -First 1)
}

function Install-VSBuildTools {
    $existing = Get-VSBuildToolsPath
    if ($existing) {
        Write-Log ('Visual Studio C++ Build Tools detected: {0}' -f $existing) -Level SUCCESS
        return
    }

    Write-Log 'Visual Studio C++ Build Tools not detected; installing prerequisite'

    $bootstrapper = Join-Path $DownloadPath 'vs_BuildTools.exe'
    $bootstrapperUrl = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'

    Write-Log 'Downloading Visual Studio 2022 Build Tools bootstrapper'
    Invoke-WebRequest -Uri $bootstrapperUrl -OutFile $bootstrapper -UseBasicParsing

    if (-not (Test-Path -LiteralPath $bootstrapper) -or (Get-Item -LiteralPath $bootstrapper).Length -lt 1MB) {
        throw 'Visual Studio Build Tools bootstrapper download failed or is too small.'
    }

    Test-InstallerIntegrity -Path $bootstrapper -ExpectedPublishers @('Microsoft Corporation')

    Write-Log 'Installing Visual Studio 2022 Build Tools with Desktop development with C++'
    Write-Log 'This prerequisite installation can take several minutes.'

    $vsArgs = @(
        '--quiet'
        '--wait'
        '--norestart'
        '--nocache'
        '--add'
        'Microsoft.VisualStudio.Workload.VCTools'
        '--includeRecommended'
    )

    $process = Start-Process -FilePath $bootstrapper -ArgumentList $vsArgs -PassThru -WindowStyle Hidden
    while (-not $process.HasExited) {
        Start-Sleep -Seconds 30
        $process.Refresh()
        if (-not $process.HasExited) {
            Write-Log 'Visual Studio Build Tools installation is still running...'
        }
    }

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw ('Visual Studio Build Tools installer exit code {0}' -f $process.ExitCode)
    }

    if ($process.ExitCode -eq 3010) {
        Write-Log 'Visual Studio Build Tools requested a reboot; continuing verification' -Level WARN
    }

    $installedPath = Get-VSBuildToolsPath
    if (-not $installedPath) {
        throw 'Visual Studio Build Tools installation finished, but the MSVC x64/x86 toolchain was not detected.'
    }

    Write-Log ('Visual Studio C++ Build Tools installed: {0}' -f $installedPath) -Level SUCCESS
    Remove-Item -LiteralPath $bootstrapper -Force -ErrorAction SilentlyContinue
}

function Get-InstalledAppVersion {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($base in $paths) {
        $apps = Get-ItemProperty $base -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Intel.*(oneAPI|Fortran)' }

        foreach ($app in @($apps)) {
            if ($app.DisplayVersion) {
                return $app.DisplayVersion
            }
        }
    }

    return $null
}

function Get-AppDownloadInfo {
    [pscustomobject]@{
        Version  = '2026.1.1.32'
        FileName = 'intel-oneapi-toolkit-2026.1.1.32_offline.exe'
        Url      = 'https://registrationcenter-download.intel.com/akdlm/IRC_NAS/0cb67a0d-67f6-410b-868b-f4a0a17ff0cf/intel-oneapi-toolkit-2026.1.1.32_offline.exe'
    }
}

function Test-FortranInstalled {
    $ifxCandidates = @(
        'C:\Program Files (x86)\Intel\oneAPI\compiler\latest\bin\ifx.exe',
        'C:\Program Files\Intel\oneAPI\compiler\latest\bin\ifx.exe'
    )

    foreach ($candidate in $ifxCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            Write-Log ('IFX found: {0}' -f $candidate) -Level SUCCESS
            return
        }
    }

    throw 'Intel Fortran is registered as installed, but ifx.exe was not found.'
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-{0}_{1}.log" -f ($AppName -replace '\s', ''), (Get-Date -Format 'yyyyMMdd'))
}

Write-Log ('Starting {0} install' -f $AppName)

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path -LiteralPath $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    # Intel Fortran on Windows requires the Microsoft C++ build environment.
    Install-VSBuildTools

    $installedVersion = Get-InstalledAppVersion
    if ($installedVersion -and -not $Force) {
        Write-Log ('Intel oneAPI/Fortran already installed: {0}' -f $installedVersion)
        Test-FortranInstalled
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log ('Found Intel installation {0}; Force specified' -f $installedVersion) -Level WARN
    }
    else {
        Write-Log 'Intel Fortran not detected; installing'
    }

    $downloadInfo = Get-AppDownloadInfo
    $packagePath = Join-Path $DownloadPath $downloadInfo.FileName

    if (-not (Test-Path -LiteralPath $packagePath)) {
        Write-Log ('Downloading Intel oneAPI Toolkit {0}' -f $downloadInfo.Version)
        Write-Log 'The Intel offline installer is large; this download can take some time.'
        Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $packagePath -UseBasicParsing
    }
    else {
        Write-Log ('Using existing installer: {0}' -f $packagePath)
    }

    if (-not (Test-Path -LiteralPath $packagePath) -or (Get-Item -LiteralPath $packagePath).Length -lt 10MB) {
        throw 'Intel installer download failed or the file is too small.'
    }

    $integrityParams = @{
        Path               = $packagePath
        ExpectedPublishers = @('Intel Corporation')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Installing Intel Fortran'
    Write-Log 'The Intel installation can take 30 minutes or longer. Progress will be logged every 60 seconds.'

    $intelArgs = @(
        '-s'
        '-a'
        '--silent'
        '--eula'
        'accept'
    )

    $process = Start-Process -FilePath $packagePath -ArgumentList $intelArgs -PassThru -WindowStyle Hidden
    $elapsed = 0
    while (-not $process.HasExited) {
        Start-Sleep -Seconds 60
        $elapsed += 1
        $process.Refresh()
        if (-not $process.HasExited) {
            Write-Log ('Intel Fortran installation is still running ({0} minute(s) elapsed)...' -f $elapsed)
        }
    }

    Write-Log ('Intel installer exited with code {0}' -f $process.ExitCode)
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw ('Intel installer exit code {0}' -f $process.ExitCode)
    }

    $newVersion = Get-InstalledAppVersion
    if (-not $newVersion) {
        throw 'Intel installer finished but the installed product was not detected.'
    }
    Write-Log ('Installed Intel oneAPI/Fortran: {0}' -f $newVersion) -Level SUCCESS

    Test-FortranInstalled

    Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    Write-Log ('See log: {0}' -f $script:LogPath) -Level ERROR
    exit 1
}
