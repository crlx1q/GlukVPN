<#
.SYNOPSIS
    Builds the portable GlukVPN Desktop package.

.DESCRIPTION
    Produces:
      dist\GlukVPN-portable-<version>.zip     always
      dist\GlukVPN-<version>-portable.exe     with -SingleFile (needs 7-Zip)

    Honest note about "one exe"
    ---------------------------
    Flutter Windows emits glukvpn.exe plus flutter_windows.dll, the plugin
    DLLs and a data\ folder. There is no supported way to fuse those into a
    single PE image. -SingleFile therefore builds a 7-Zip self-extracting
    archive: the user still double-clicks exactly one file, it unpacks to
    %LOCALAPPDATA%\GlukVPN\app and launches the UI.

    User data always lives in %APPDATA%\GlukVPN, so the portable build keeps
    its settings, session and statistics like the installed one.

    The VPN itself still needs the privileged service, which must be
    registered once. run-portable.cmd does that with a single UAC prompt.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StageDir,

    [Parameter(Mandatory = $true)]
    [string]$OutDir,

    [string]$Version = '1.0.0',

    [switch]$SingleFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $StageDir)) {
    throw "Stage directory not found: $StageDir. Run build-all.ps1 first."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------------------------------------------------------------------------
# Portable launcher
# ---------------------------------------------------------------------------

$launcher = @'
@echo off
rem GlukVPN portable launcher.
rem Registers the tunnel service on first run, then starts the app.

setlocal
set "HERE=%~dp0"

sc query GlukVpnTunnel >nul 2>&1
if errorlevel 1 (
    echo Registering the GlukVPN tunnel service. Windows will ask for permission.
    powershell -NoProfile -Command ^
        "Start-Process -FilePath '%HERE%service\GlukVpnTunnelService.exe' -ArgumentList '--install' -Verb RunAs -Wait"
)

start "" "%HERE%glukvpn.exe" %*
endlocal
'@

Set-Content -Path (Join-Path $StageDir 'run-portable.cmd') `
    -Value $launcher -Encoding ASCII

# ---------------------------------------------------------------------------
# Portable readme
# ---------------------------------------------------------------------------

$readme = @"
GlukVPN Desktop $Version - portable
===================================

1. Unpack this folder anywhere.
2. Run run-portable.cmd.
   The first launch registers the GlukVPN tunnel service, so Windows shows one
   permission prompt. After that it never asks again.
3. Sign in with your existing GlukVPN account and press Connect.

Where your data lives
---------------------
  %APPDATA%\GlukVPN\settings.json    settings
  %APPDATA%\GlukVPN\usage.json       statistics
  %APPDATA%\GlukVPN\secure\          session (encrypted with Windows DPAPI)
  %PROGRAMDATA%\GlukVPN\logs\        service log

Removing it
-----------
  service\GlukVpnTunnelService.exe --uninstall     (as administrator)
  then delete this folder and %APPDATA%\GlukVPN.

Why is there more than one file?
--------------------------------
A Flutter Windows app is always an .exe plus flutter_windows.dll and a data\
folder. The single-file build is a self-extracting archive around exactly this
folder - the contents are identical.
"@

Set-Content -Path (Join-Path $StageDir 'README.txt') -Value $readme -Encoding UTF8

# ---------------------------------------------------------------------------
# ZIP
# ---------------------------------------------------------------------------

$zipPath = Join-Path $OutDir "GlukVPN-portable-$Version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Host "Compressing $zipPath" -ForegroundColor Cyan
Compress-Archive -Path (Join-Path $StageDir '*') -DestinationPath $zipPath `
    -CompressionLevel Optimal

Write-Host "    $([Math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB" `
    -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Self-extracting exe
# ---------------------------------------------------------------------------

if ($SingleFile) {
    $sevenZip = Get-Command '7z' -ErrorAction SilentlyContinue
    if (-not $sevenZip) {
        $guess = 'C:\Program Files\7-Zip\7z.exe'
        if (Test-Path $guess) {
            $sevenZip = $guess
        } else {
            Write-Warning '7-Zip not found; skipping the single-file build. Install it from https://www.7-zip.org/'
            return
        }
    } else {
        $sevenZip = $sevenZip.Source
    }

    $sfxModule = Join-Path (Split-Path -Parent $sevenZip) '7z.sfx'
    if (-not (Test-Path $sfxModule)) {
        Write-Warning "7z.sfx not found next to 7z.exe; skipping the single-file build."
        return
    }

    Write-Host 'Building the self-extracting executable' -ForegroundColor Cyan

    $temp7z = Join-Path $OutDir "GlukVPN-$Version.7z"
    if (Test-Path $temp7z) { Remove-Item $temp7z -Force }

    & $sevenZip a -t7z -mx=9 $temp7z (Join-Path $StageDir '*') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '7-Zip archiving failed.' }

    $config = @"
;!@Install@!UTF-8!
Title="GlukVPN $Version"
ExtractDialogText="Starting GlukVPN..."
ExtractTitle="GlukVPN"
InstallPath="%LOCALAPPDATA%\\GlukVPN\\app"
RunProgram="run-portable.cmd"
GUIMode="2"
OverwriteMode="2"
;!@InstallEnd@!
"@

    $configPath = Join-Path $OutDir 'sfx-config.txt'
    # 7-Zip SFX configs must be UTF-8 without a BOM.
    [System.IO.File]::WriteAllText(
        $configPath, $config, (New-Object System.Text.UTF8Encoding($false)))

    $sfxPath = Join-Path $OutDir "GlukVPN-$Version-portable.exe"
    if (Test-Path $sfxPath) { Remove-Item $sfxPath -Force }

    # SFX module + config + archive, concatenated in that exact order.
    $output = [System.IO.File]::Create($sfxPath)
    try {
        foreach ($part in @($sfxModule, $configPath, $temp7z)) {
            $bytes = [System.IO.File]::ReadAllBytes($part)
            $output.Write($bytes, 0, $bytes.Length)
        }
    }
    finally {
        $output.Dispose()
    }

    Remove-Item $temp7z, $configPath -Force

    Write-Host "    $sfxPath" -ForegroundColor DarkGray
    Write-Host "    $([Math]::Round((Get-Item $sfxPath).Length / 1MB, 1)) MB" `
        -ForegroundColor DarkGray
}

Write-Host 'Portable package ready.' -ForegroundColor Green
