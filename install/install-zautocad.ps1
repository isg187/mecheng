<#
.SYNOPSIS
    Installs AutoCAD from a local path or later a storage URL.

.PARAMETER SourcePath
    Full path to setup.exe, an extracted folder, a zip, or a download URL.

.PARAMETER InstallArgs
    Installer arguments. Default is /q.

.EXAMPLE
    .\install-autocad.ps1 -SourcePath 'C:\Installers\AutoCAD\setup.exe'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'AutoCadInstall'),
    [string]$InstallArgs = '/q'
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
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    $logDir = Split-Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Get-InstalledAutoCad {
    $root = Join-Path $env:ProgramFiles 'Autodesk'
    if (Test-Path -LiteralPath $root) {
        $exe = Get-ChildItem -LiteralPath $root -Filter 'acad.exe' -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($exe) { return $exe.DirectoryName }
    }

    $years = 2027, 2026, 2025, 2024
    foreach ($year in $years) {
        $dir = Join-Path $env:ProgramFiles ("Autodesk\AutoCAD {0}" -f $year)
        if (Test-Path -LiteralPath $dir) { return $dir }
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
        'setup.exe'
        'Setup.exe'
    )

    foreach ($name in $preferred) {
        $hit = Get-ChildItem -LiteralPath $Path -Filter $name -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($hit) { return $hit }
    }

    throw "No AutoCAD setup.exe found under $Path"
}

function Get-LocalSource {
    param([string]$Source)

    if ($Source -match '^https?://') {
        if (-not (Test-Path $DownloadPath)) {
            New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
        }

        $fileName = ([uri]$Source).Segments[-1]
        if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -eq '/') {
            $fileName = 'AutoCAD.exe'
        }
        $fileName = [uri]::UnescapeDataString($fileName)
        if ($fileName.Contains('?')) {
            $fileName = $fileName.Split('?')[0]
        }

        $outFile = Join-Path $DownloadPath $fileName
        Write-Log 'Downloading AutoCAD installer'
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
    $script:LogPath = Join-Path $logDir ("Install-AutoCad_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting AutoCAD install'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $existing = Get-InstalledAutoCad
    if ($existing -and -not $Force) {
        Write-Log ('AutoCAD already installed: {0}' -f $existing) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($existing -and $Force) {
        Write-Log 'AutoCAD found; Force specified' -Level WARN
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

    Write-Log 'Installing AutoCAD'
    $processParams = @{
        FilePath         = $filePath
        ArgumentList     = $argLine
        WorkingDirectory = $installer.DirectoryName
        Wait             = $true
        PassThru         = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "AutoCAD installer returned exit code $($process.ExitCode)"
    }

    $installed = Get-InstalledAutoCad
    if ($installed) {
        Write-Log ('AutoCAD installed: {0}' -f $installed) -Level SUCCESS
    }
    else {
        Write-Log 'Installer finished but AutoCAD was not detected.' -Level WARN
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
