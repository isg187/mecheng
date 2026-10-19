<#
.SYNOPSIS
    Installs Thermal Desktop 2026 R1.01 from a local path or later a storage URL.

.PARAMETER SourcePath
    Full path to the installer file, an extracted folder, or a download URL.
    Examples:
      C:\Installers\THERMALDESKTOP_2026R1.01_WINX64.exe
      C:\Installers\THERMALDESKTOP_2026R1.01_WINX64.zip
      C:\Installers\THERMALDESKTOP_2026R1.01_WINX64
      https://<storageaccount>.blob.core.windows.net/<container>/THERMALDESKTOP_2026R1.01_WINX64.exe?<sas>

.PARAMETER InstallArgs
    Optional extra installer arguments. Default is Ansys silent: -silent

.EXAMPLE
    .\install-thermaldesktop.ps1 -SourcePath 'C:\Installers\THERMALDESKTOP_2026R1.01_WINX64.exe'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'ThermalDesktopInstall'),
    [string]$InstallArgs = '-silent -thermaldesktop -sinda'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [string]$Message,
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

    $logDir = Split-Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Get-InstalledThermalDesktop {
    $dir = Join-Path $env:ProgramFiles 'ANSYS Inc\v261\CRTech\Thermal Desktop'
    $exe = Join-Path $dir 'CurrentTDInstalled64.exe'

    if (Test-Path -LiteralPath $exe) {
        return $true
    }
    if (Test-Path -LiteralPath $dir) {
        return 'v261'
    }
    return $null
}

function Resolve-InstallerFile {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-Item -LiteralPath $Path)
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Installer path not found: $Path"
    }

    $preferred = @(
        'THERMALDESKTOP_2026R1.01_WINX64.exe'
        'THERMALDESKTOP_2026R1.01_WINX64.msi'
        'setup.exe'
        'AnsysInstaller.exe'
    )

    foreach ($name in $preferred) {
        $hit = Get-ChildItem -LiteralPath $Path -Filter $name -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit }
    }

    $exe = Get-ChildItem -LiteralPath $Path -Include *.exe, *.msi -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'THERMALDESKTOP|ThermalDesktop|setup|AnsysInstaller' } |
        Select-Object -First 1
    if ($exe) { return $exe }

    throw "No Thermal Desktop installer found under $Path"
}

function Get-LocalSource {
    param([string]$Source)

    if ($Source -match '^https?://') {
        if (-not (Test-Path $DownloadPath)) {
            New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
        }

        $fileName = ([uri]$Source).Segments[-1]
        if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -eq '/') {
            $fileName = 'THERMALDESKTOP_2026R1.01_WINX64.exe'
        }
        $fileName = [uri]::UnescapeDataString($fileName)
        if ($fileName.Contains('?')) {
            $fileName = $fileName.Split('?')[0]
        }

        $outFile = Join-Path $DownloadPath $fileName
        Write-Log 'Downloading Thermal Desktop installer'
        Invoke-WebRequest -Uri $Source -OutFile $outFile -UseBasicParsing
        return $outFile
    }

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "SourcePath not found: $Source"
    }

    return (Resolve-Path -LiteralPath $Source).Path
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-ThermalDesktop_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting Thermal Desktop 2026 R1.01 install'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $existing = Get-InstalledThermalDesktop
    if ($existing -and -not $Force) {
        $ver = $existing.DisplayVersion
        if (-not $ver) { $ver = $existing.DisplayName }
        Write-Log ('Thermal Desktop already installed: {0}' -f $ver) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($existing -and $Force) {
        Write-Log 'Thermal Desktop found; Force specified' -Level WARN
    }

    $localSource = Get-LocalSource -Source $SourcePath
    Write-Log ("Source: {0}" -f $localSource)

    if ((Test-Path -LiteralPath $localSource -PathType Leaf) -and ([IO.Path]::GetExtension($localSource) -eq '.zip')) {
        $extractPath = Join-Path $DownloadPath 'extracted'
        if (Test-Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force
        }
        Write-Log 'Extracting zip'
        Expand-Archive -Path $localSource -DestinationPath $extractPath -Force
        $localSource = $extractPath
    }

    $installer = Resolve-InstallerFile -Path $localSource
    Write-Log ("Installer: {0}" -f $installer.FullName)

    $ext = $installer.Extension.ToLowerInvariant()
    if ($ext -eq '.msi') {
        $argLine = '/i "{0}" /qn /norestart ALLUSERS=1' -f $installer.FullName
        $filePath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    }
    else {
        $argLine = $InstallArgs
        $filePath = $installer.FullName
    }

    Write-Log 'Installing Thermal Desktop'
    $processParams = @{
        FilePath     = $filePath
        ArgumentList = $argLine
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "Thermal Desktop installer returned exit code $($process.ExitCode)"
    }

    $installed = Get-InstalledThermalDesktop
    if ($installed) {
        $ver = $installed.DisplayVersion
        if (-not $ver) { $ver = $installed.DisplayName }
        Write-Log ('Thermal Desktop installed: {0}' -f $ver) -Level SUCCESS
    }
    else {
        Write-Log 'Installer finished but Thermal Desktop was not detected.' -Level WARN
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
